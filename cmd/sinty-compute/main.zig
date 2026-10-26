const std = @import("std");
const linux = std.os.linux;
const sc = @import("sintycompute");

const SYSFS = "/sys/kernel/sinty_compute/";
const FIELDS = [_][]const u8{ "enabled", "mode", "contexts", "ranges", "hits", "misses", "verified", "mismatches", "saved_ns", "spent_ns", "invalidations" };

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "sinty-compute: " ++ fmt ++ "\n", args) catch "sinty-compute: error\n";
    _ = linux.write(2, s.ptr, s.len);
    linux.exit(1);
}

fn readSys(name: []const u8, buf: []u8) ?[]const u8 {
    var pbuf: [128]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pbuf, SYSFS ++ "{s}", .{name}, 0) catch return null;
    const r = linux.open(p.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(r) != .SUCCESS) return null;
    const fd: i32 = @intCast(r);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return std.mem.trim(u8, buf[0..n], " \n");
}

fn status() u8 {
    var buf: [64]u8 = undefined;
    if (readSys("enabled", &buf) == null) {
        out("module: not loaded\n", .{});
        return 1;
    }
    out("module: loaded\n", .{});
    for (FIELDS) |f| out("{s}: {s}\n", .{ f, readSys(f, &buf) orelse "?" });
    return 0;
}

fn generation(fd: c_int, id: u64) u64 {
    var g: u64 = 0;
    const e = sc.sinty_compute_generation(fd, id, &g);
    if (e != 0) fatal("generation: error {d}", .{e});
    return g;
}

fn check(name: []const u8, ok: bool, fails: *u32) void {
    out("{s}: {s}\n", .{ if (ok) "ok  " else "FAIL", name });
    if (!ok) fails.* += 1;
}

fn probe() u8 {
    const fd = sc.sinty_compute_open();
    if (fd < 0) fatal("cannot open /dev/sinty-compute: error {d}", .{fd});
    defer sc.sinty_compute_close(fd);
    const page: usize = 4096;
    const m = linux.mmap(null, page * 4, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(m) != .SUCCESS) fatal("mmap failed", .{});
    const mem: [*]u8 = @ptrFromInt(m);
    @memset(mem[0 .. page * 4], 7);
    var fails: u32 = 0;

    var a: u64 = 0;
    var b: u64 = 0;
    check("track two ranges", sc.sinty_compute_track(fd, mem, page * 2, &a) == 0 and sc.sinty_compute_track(fd, mem + page * 2, page * 2, &b) == 0, &fails);
    const a0 = generation(fd, a);
    const b0 = generation(fd, b);
    mem[10] = 9;
    check("plain writes leave the kernel generation alone", generation(fd, a) == a0, &fails);
    _ = linux.madvise(mem, page, linux.MADV.DONTNEED);
    check("discarding a page bumps its range", generation(fd, a) > a0, &fails);
    check("the other range is untouched", generation(fd, b) == b0, &fails);
    _ = linux.mprotect(mem + page * 2, page, .{ .READ = true });
    check("changing protection keeps contents", generation(fd, b) == b0, &fails);
    _ = linux.munmap(mem + page * 2, page * 2);
    check("unmapping bumps its range", generation(fd, b) > b0, &fails);
    check("untrack", sc.sinty_compute_untrack(fd, b) == 0, &fails);
    var g: u64 = 0;
    check("untracked ranges are gone", sc.sinty_compute_generation(fd, b, &g) == -@as(c_int, @intFromEnum(linux.E.NOENT)), &fails);
    const r: sc.Report = .{ .hits = 3, .misses = 1, .saved_ns = 1000, .spent_ns = 50 };
    check("report", sc.sinty_compute_report(fd, &r) == 0, &fails);
    var buf: [64]u8 = undefined;
    const hits = std.fmt.parseInt(u64, readSys("hits", &buf) orelse "0", 10) catch 0;
    check("statistics reach sysfs", hits >= 3, &fails);
    _ = linux.munmap(mem, page * 2);
    out("{s}\n", .{if (fails == 0) "probe passed" else "probe failed"});
    return if (fails == 0) 0 else 1;
}

const Job = struct {
    base: [*]const u8,
    off: usize,
    len: usize,
    rounds: u32,
};

fn digest(j: *const Job, d: *[32]u8) void {
    var h: [4]u64 = .{ 0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1 };
    var r: u32 = 0;
    while (r < j.rounds) : (r += 1) {
        for (j.base[j.off .. j.off + j.len], 0..) |b, i| {
            const x = &h[i & 3];
            x.* = std.math.rotl(u64, x.* ^ (@as(u64, b) +% i +% r), 23) *% 0x9E3779B97F4A7C15;
        }
    }
    for (h, 0..) |v, i| std.mem.writeInt(u64, d[i * 8 ..][0..8], v, .little);
}

noinline fn work(arg: ?*anyopaque, o: ?*anyopaque, len: usize) callconv(.c) c_int {
    if (len != 32) return -22;
    const j: *const Job = @ptrCast(@alignCast(arg.?));
    digest(j, @ptrCast(o.?));
    return 0;
}

fn clock() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const SLOTS = 16;
const SLOT = 16384;

const Bench = struct {
    ctx: *sc.reuse.Ctx,
    mem: [*]u8,
    inputs: [SLOTS]u32,
    calls: u64 = 0,

    fn call(b: *Bench, slot: usize, off: usize, len: usize, rounds: u32, res: *[32]u8) c_int {
        var j: Job = .{ .base = b.mem, .off = slot * SLOT + off, .len = len, .rounds = rounds };
        const key = [3]u64{ j.off, j.len, rounds };
        b.calls += 1;
        return sc.reuse.sinty_compute_call(b.ctx, 1, &key, @sizeOf(@TypeOf(key)), @ptrCast(&b.inputs[slot]), 1, res, 32, work, &j);
    }

    fn report(b: *Bench) sc.Report {
        var r: sc.Report = .{};
        sc.reuse.sinty_compute_ctx_report(b.ctx, &r);
        return r;
    }
};

fn selftest(calls: u64) u8 {
    const fd = sc.sinty_compute_open();
    if (fd < 0) fatal("cannot open /dev/sinty-compute: error {d}", .{fd});
    var enabled: c_int = 0;
    var mode: c_int = 0;
    _ = sc.sinty_compute_state(fd, &enabled, &mode);
    sc.sinty_compute_close(fd);
    if (enabled == 0) fatal("the feature is switched off", .{});
    const names = [_][]const u8{ "measure", "active", "verify" };
    out("mode: {s}\n", .{names[@intCast(mode)]});
    const ctx = sc.reuse.sinty_compute_ctx_new(16 << 20) orelse fatal("cannot create a context (userfaultfd or pagemap unavailable)", .{});
    defer sc.reuse.sinty_compute_ctx_free(ctx);
    if (mode == sc.SINTY_COMPUTE_VERIFY) sc.reuse.sinty_compute_ctx_set_verify(ctx, 1);
    const m = linux.mmap(null, SLOTS * SLOT, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(m) != .SUCCESS) fatal("mmap failed", .{});
    const mem: [*]u8 = @ptrFromInt(m);
    var seed: u64 = 0x1234567;
    for (mem[0 .. SLOTS * SLOT]) |*x| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        x.* = @truncate(seed >> 33);
    }
    var b: Bench = .{ .ctx = ctx, .mem = mem, .inputs = undefined };
    for (0..SLOTS) |i| {
        const e = sc.reuse.sinty_compute_input(ctx, mem + i * SLOT, SLOT, &b.inputs[i]);
        if (e != 0) fatal("input {d}: error {d}", .{ i, e });
    }
    var fails: u32 = 0;
    var o1: [32]u8 = undefined;
    var o2: [32]u8 = undefined;
    var want: [32]u8 = undefined;
    const reuses = mode != sc.SINTY_COMPUTE_MEASURE;

    var r0 = b.report();
    _ = b.call(0, 100, 4000, 4, &o1);
    var r1 = b.report();
    check("first call computes", r1.misses == r0.misses + 1, &fails);
    _ = b.call(0, 100, 4000, 4, &o2);
    r0 = r1;
    r1 = b.report();
    check("same key and inputs is a hit", r1.hits == r0.hits + 1 and std.mem.eql(u8, &o1, &o2), &fails);
    mem[3 * SLOT + 9] +%= 1;
    _ = b.call(0, 100, 4000, 4, &o2);
    r0 = r1;
    r1 = b.report();
    check("a write to another input keeps the result", r1.hits == r0.hits + 1, &fails);
    mem[0 * SLOT + 200] +%= 1;
    _ = b.call(0, 100, 4000, 4, &o2);
    r0 = r1;
    r1 = b.report();
    var j: Job = .{ .base = mem, .off = 100, .len = 4000, .rounds = 4 };
    digest(&j, &want);
    check("a write to the input invalidates the result", r1.misses == r0.misses + 1 and std.mem.eql(u8, &o2, &want), &fails);
    _ = b.call(0, 100, 4000, 4, &o2);
    _ = linux.madvise(mem, SLOT, linux.MADV.DONTNEED);
    _ = b.call(0, 100, 4000, 4, &o2);
    r0 = r1;
    r1 = b.report();
    digest(&j, &want);
    check("discarding the pages invalidates the result", r1.misses == r0.misses + 1 and std.mem.eql(u8, &o2, &want), &fails);
    _ = b.call(0, 100, 4001, 4, &o2);
    r0 = r1;
    r1 = b.report();
    check("a different key computes", r1.misses == r0.misses + 1, &fails);

    const start = b.report();
    const base_mem: [*]u8 = @ptrFromInt(linux.mmap(null, SLOTS * SLOT, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0));
    @memcpy(base_mem[0 .. SLOTS * SLOT], mem[0 .. SLOTS * SLOT]);
    var direct_ns: u64 = std.math.maxInt(u64);
    var runtime_ns: u64 = std.math.maxInt(u64);
    var stale: u64 = 0;
    var writes: u64 = 0;
    for (0..6) |round| {
        const pass = round % 2;
        var pass_ns: u64 = 0;
        var rng: u64 = 0x9E3779B97F4A7C15;
        const t0 = clock();
        var n: u64 = 0;
        while (n < calls) : (n += 1) {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            const slot: usize = @intCast(rng % SLOTS);
            const k: usize = @intCast((rng >> 8) % 8);
            const target = if (pass == 0) base_mem else mem;
            if ((rng >> 20) % 1000 == 0) {
                target[slot * SLOT + @as(usize, @intCast((rng >> 32) % SLOT))] +%= 1;
                if (round == 1) writes += 1;
            }
            const off = k * 1024;
            const len: usize = 2048 + k * 512;
            if (pass == 0) {
                var jj: Job = .{ .base = base_mem, .off = slot * SLOT + off, .len = len, .rounds = 2 };
                _ = work(&jj, &want, 32);
                std.mem.doNotOptimizeAway(&want);
            } else {
                _ = b.call(slot, off, len, 2, &o1);
                if (n % 64 == 0) {
                    var jj: Job = .{ .base = mem, .off = slot * SLOT + off, .len = len, .rounds = 2 };
                    const t2 = clock();
                    _ = work(&jj, &want, 32);
                    pass_ns +%= clock() - t2;
                    if (!std.mem.eql(u8, &o1, &want)) stale += 1;
                }
            }
        }
        const dt = clock() - t0;
        if (pass == 0) direct_ns = @min(direct_ns, dt) else runtime_ns = @min(runtime_ns, dt -% pass_ns);
    }
    const end = b.report();
    out("calls: {d}\nwrites: {d}\nhits: {d}\nmisses: {d}\nverified: {d}\nmismatches: {d}\n", .{ calls * 3, writes * 3, end.hits - start.hits, end.misses - start.misses, end.verified - start.verified, end.mismatches - start.mismatches });
    out("cache: {d} bytes\n", .{sc.reuse.sinty_compute_ctx_used(ctx)});
    out("time with the runtime: {d} ms\ntime without: {d} ms\n", .{ runtime_ns / std.time.ns_per_ms, direct_ns / std.time.ns_per_ms });
    check("no stale result in the sampled calls", stale == 0, &fails);
    check("no difference in shadow verification", end.mismatches == start.mismatches, &fails);
    if (mode == sc.SINTY_COMPUTE_VERIFY) check("every reuse was verified", end.verified - start.verified == end.hits - start.hits, &fails);
    if (reuses and mode == sc.SINTY_COMPUTE_ACTIVE) check("reuse is faster than computing", runtime_ns < direct_ns, &fails);
    out("{s}\n", .{if (fails == 0) "selftest passed" else "selftest failed"});
    return if (fails == 0) 0 else 1;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cmd = if (args.len > 1) args[1] else "status";
    if (std.mem.eql(u8, cmd, "status")) return status();
    if (std.mem.eql(u8, cmd, "probe")) return probe();
    if (std.mem.eql(u8, cmd, "selftest")) return selftest(if (args.len > 2) std.fmt.parseInt(u64, args[2], 10) catch fatal("bad call count", .{}) else 1000000);
    fatal("usage: sinty-compute [status|probe|selftest [calls]]", .{});
}
