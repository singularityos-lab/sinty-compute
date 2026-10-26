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

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cmd = if (args.len > 1) args[1] else "status";
    if (std.mem.eql(u8, cmd, "status")) return status();
    if (std.mem.eql(u8, cmd, "probe")) return probe();
    fatal("usage: sinty-compute [status|probe]", .{});
}
