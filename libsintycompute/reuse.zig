const std = @import("std");
const linux = std.os.linux;
const sc = @import("sintycompute.zig");

const UFFD_API: u64 = 0xAA;
const UFFD_USER_MODE_ONLY: usize = 1;
const O_NONBLOCK: usize = 0o4000;
const O_CLOEXEC: usize = 0o2000000;
const UFFD_FEATURE_WP_UNPOPULATED: u64 = 1 << 13;
const UFFD_FEATURE_WP_ASYNC: u64 = 1 << 15;
const UFFDIO_REGISTER_MODE_WP: u64 = 2;
const UFFDIO_WRITEPROTECT_MODE_WP: u64 = 1;
const PM_SCAN_WP_MATCHING: u64 = 1;
const PM_SCAN_CHECK_WPASYNC: u64 = 2;
const PAGE_IS_WRITTEN: u64 = 2;

const UffdRange = extern struct { start: u64, len: u64 };
const UffdApi = extern struct { api: u64, features: u64, ioctls: u64 };
const UffdRegister = extern struct { range: UffdRange, mode: u64, ioctls: u64 };
const UffdWriteprotect = extern struct { range: UffdRange, mode: u64 };
const PageRegion = extern struct { start: u64, end: u64, categories: u64 };
const PmScanArg = extern struct {
    size: u64,
    flags: u64,
    start: u64,
    end: u64,
    walk_end: u64,
    vec: u64,
    vec_len: u64,
    max_pages: u64,
    category_inverted: u64,
    category_mask: u64,
    category_anyof_mask: u64,
    return_mask: u64,
};

const UFFDIO_API = linux.IOCTL.IOWR(0xAA, 0x3F, UffdApi);
const UFFDIO_REGISTER = linux.IOCTL.IOWR(0xAA, 0x00, UffdRegister);
const UFFDIO_UNREGISTER = linux.IOCTL.IOR(0xAA, 0x01, UffdRange);
const UFFDIO_WRITEPROTECT = linux.IOCTL.IOWR(0xAA, 0x06, UffdWriteprotect);
const PAGEMAP_SCAN = linux.IOCTL.IOWR('f', 16, PmScanArg);

const PAGE: usize = 4096;
const BUCKETS: usize = 4096;
const REPORT_EVERY: u32 = 256;
const DEFAULT_VERIFY_EVERY: u32 = 16;
const MAX_INPUTS: usize = 1024;

const EINVAL: c_int = -22;
const ENOMEM: c_int = -12;
const ENOSPC: c_int = -28;
const ENOENT: c_int = -2;

pub const Fn = *const fn (arg: ?*anyopaque, out: ?*anyopaque, out_len: usize) callconv(.c) c_int;

const Lock = struct {
    v: std.atomic.Value(u32) = .init(0),

    fn lock(l: *Lock) void {
        while (l.v.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) _ = linux.sched_yield();
    }

    fn unlock(l: *Lock) void {
        l.v.store(0, .release);
    }
};

const Input = struct {
    start: usize,
    end: usize,
    kid: u64,
    writes: u64,
    live: bool,
};

const Gen = struct {
    input: u32,
    kernel: u64,
    writes: u64,
};

const Entry = struct {
    region: u32,
    hash: u64,
    key: []u8,
    gens: []Gen,
    out: []u8,
    cost_ns: u64,
    chain: ?*Entry,
    prev: ?*Entry,
    next: ?*Entry,

    fn size(e: *const Entry) usize {
        return @sizeOf(Entry) + e.key.len + e.out.len + e.gens.len * @sizeOf(Gen);
    }
};

pub const Ctx = struct {
    lock: Lock = .{},
    gpa: std.mem.Allocator,
    kfd: c_int,
    uffd: c_int,
    pmfd: c_int,
    inputs: []Input,
    n_inputs: u32 = 0,
    table: []?*Entry,
    head: ?*Entry = null,
    tail: ?*Entry = null,
    used: usize = 0,
    budget: usize,
    state: u32 = 0,
    verify_every: u32 = DEFAULT_VERIFY_EVERY,
    verify_tick: u32 = 0,
    disabled: std.ArrayList(u32) = .empty,
    pending: sc.Report = .{},
    total: sc.Report = .{},
    calls: u32 = 0,
    gens: std.ArrayList(Gen) = .empty,
};

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn ok(r: usize) bool {
    return linux.errno(r) == .SUCCESS;
}

fn err(r: usize) c_int {
    return -@as(c_int, @intCast(@intFromEnum(linux.errno(r))));
}

fn openUffd() c_int {
    const r = linux.syscall1(.userfaultfd, O_CLOEXEC | O_NONBLOCK | UFFD_USER_MODE_ONLY);
    if (!ok(r)) return err(r);
    const fd: c_int = @intCast(r);
    var api: UffdApi = .{ .api = UFFD_API, .features = UFFD_FEATURE_WP_ASYNC | UFFD_FEATURE_WP_UNPOPULATED, .ioctls = 0 };
    const a = linux.ioctl(fd, UFFDIO_API, @intFromPtr(&api));
    if (!ok(a)) {
        _ = linux.close(fd);
        return err(a);
    }
    return fd;
}

fn protect(c: *Ctx, start: usize, end: usize) c_int {
    var wp: UffdWriteprotect = .{ .range = .{ .start = start, .len = end - start }, .mode = UFFDIO_WRITEPROTECT_MODE_WP };
    const r = linux.ioctl(c.uffd, UFFDIO_WRITEPROTECT, @intFromPtr(&wp));
    return if (ok(r)) 0 else err(r);
}

fn written(c: *Ctx, in: *const Input) bool {
    var reg: [1]PageRegion = undefined;
    var a: PmScanArg = .{
        .size = @sizeOf(PmScanArg),
        .flags = PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC,
        .start = in.start,
        .end = in.end,
        .walk_end = 0,
        .vec = @intFromPtr(&reg),
        .vec_len = reg.len,
        .max_pages = 0,
        .category_inverted = 0,
        .category_mask = PAGE_IS_WRITTEN,
        .category_anyof_mask = 0,
        .return_mask = PAGE_IS_WRITTEN,
    };
    var dirty = false;
    while (true) {
        const r = linux.ioctl(c.pmfd, PAGEMAP_SCAN, @intFromPtr(&a));
        if (!ok(r)) return true;
        if (r > 0) dirty = true;
        if (a.walk_end >= in.end or r == 0) break;
        a.start = a.walk_end;
    }
    return dirty;
}

fn kernelGen(c: *Ctx, in: *const Input) u64 {
    var g: u64 = 0;
    if (sc.sinty_compute_generation(c.kfd, in.kid, &g) != 0) return 0;
    return g;
}

fn flushReport(c: *Ctx) void {
    const p = c.pending;
    if (p.hits == 0 and p.misses == 0 and p.verified == 0 and p.mismatches == 0) return;
    _ = sc.sinty_compute_report(c.kfd, &p);
    c.pending = .{};
}

fn unlink(c: *Ctx, e: *Entry) void {
    if (e.prev) |p| p.next = e.next else c.head = e.next;
    if (e.next) |n| n.prev = e.prev else c.tail = e.prev;
    e.prev = null;
    e.next = null;
}

fn pushFront(c: *Ctx, e: *Entry) void {
    e.next = c.head;
    e.prev = null;
    if (c.head) |h| h.prev = e else c.tail = e;
    c.head = e;
}

fn bucket(c: *Ctx, region: u32, hash: u64) *?*Entry {
    const h = hash ^ (@as(u64, region) *% 0x9E3779B97F4A7C15);
    return &c.table[@intCast(h & (BUCKETS - 1))];
}

fn destroy(c: *Ctx, e: *Entry) void {
    const slot = bucket(c, e.region, e.hash);
    var p: *?*Entry = slot;
    while (p.*) |x| : (p = &x.chain) {
        if (x == e) {
            p.* = e.chain;
            break;
        }
    }
    unlink(c, e);
    c.used -= e.size();
    c.gpa.free(e.key);
    c.gpa.free(e.out);
    c.gpa.free(e.gens);
    c.gpa.destroy(e);
}

fn dropAll(c: *Ctx) void {
    while (c.head) |e| destroy(c, e);
}

fn dropRegion(c: *Ctx, region: u32) void {
    var it = c.head;
    while (it) |e| {
        it = e.next;
        if (e.region == region) destroy(c, e);
    }
}

fn isDisabled(c: *Ctx, region: u32) bool {
    for (c.disabled.items) |r| if (r == region) return true;
    return false;
}

fn refreshState(c: *Ctx) u32 {
    var s: u32 = 0;
    const r = linux.ioctl(c.kfd, linux.IOCTL.IOR(0xC5, 1, u32), @intFromPtr(&s));
    if (!ok(r)) s = 0;
    if (s != c.state) {
        dropAll(c);
        c.state = s;
    }
    return s;
}

fn snapshot(c: *Ctx, ids: []const u32) bool {
    c.gens.clearRetainingCapacity();
    for (ids) |id| {
        if (id >= c.n_inputs or !c.inputs[id].live) return false;
        const in = &c.inputs[id];
        if (written(c, in)) in.writes += 1;
        c.gens.append(c.gpa, .{ .input = id, .kernel = kernelGen(c, in), .writes = in.writes }) catch return false;
    }
    return true;
}

fn find(c: *Ctx, region: u32, hash: u64, key: []const u8) ?*Entry {
    var it = bucket(c, region, hash).*;
    while (it) |e| : (it = e.chain) {
        if (e.region == region and e.hash == hash and std.mem.eql(u8, e.key, key)) return e;
    }
    return null;
}

fn fresh(c: *Ctx, e: *const Entry) bool {
    if (e.gens.len != c.gens.items.len) return false;
    for (e.gens, c.gens.items) |a, b| {
        if (a.input != b.input or a.kernel != b.kernel or a.writes != b.writes or a.kernel == 0) return false;
    }
    return true;
}

fn store(c: *Ctx, region: u32, hash: u64, key: []const u8, out: []const u8, cost: u64) void {
    const need = @sizeOf(Entry) + key.len + out.len + c.gens.items.len * @sizeOf(Gen);
    if (need > c.budget) return;
    while (c.used + need > c.budget) destroy(c, c.tail orelse return);
    const e = c.gpa.create(Entry) catch return;
    const k = c.gpa.dupe(u8, key) catch {
        c.gpa.destroy(e);
        return;
    };
    const o = c.gpa.dupe(u8, out) catch {
        c.gpa.free(k);
        c.gpa.destroy(e);
        return;
    };
    const g = c.gpa.dupe(Gen, c.gens.items) catch {
        c.gpa.free(o);
        c.gpa.free(k);
        c.gpa.destroy(e);
        return;
    };
    const slot = bucket(c, region, hash);
    e.* = .{ .region = region, .hash = hash, .key = k, .gens = g, .out = o, .cost_ns = cost, .chain = slot.*, .prev = null, .next = null };
    slot.* = e;
    pushFront(c, e);
    c.used += need;
}

pub export fn sinty_compute_ctx_new(budget: usize) ?*Ctx {
    const gpa = std.heap.smp_allocator;
    const kfd = sc.sinty_compute_open();
    if (kfd < 0) return null;
    const uffd = openUffd();
    if (uffd < 0) {
        sc.sinty_compute_close(kfd);
        return null;
    }
    const pm = linux.open("/proc/self/pagemap", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (!ok(pm)) {
        _ = linux.close(uffd);
        sc.sinty_compute_close(kfd);
        return null;
    }
    const c = gpa.create(Ctx) catch return null;
    const inputs = gpa.alloc(Input, MAX_INPUTS) catch {
        gpa.destroy(c);
        return null;
    };
    const table = gpa.alloc(?*Entry, BUCKETS) catch {
        gpa.free(inputs);
        gpa.destroy(c);
        return null;
    };
    @memset(table, null);
    c.* = .{ .gpa = gpa, .kfd = kfd, .uffd = uffd, .pmfd = @intCast(pm), .inputs = inputs, .table = table, .budget = if (budget == 0) 64 << 20 else budget };
    _ = refreshState(c);
    return c;
}

pub export fn sinty_compute_ctx_free(c: ?*Ctx) void {
    const x = c orelse return;
    x.lock.lock();
    flushReport(x);
    dropAll(x);
    for (x.inputs[0..x.n_inputs]) |in| if (in.live) {
        _ = sc.sinty_compute_untrack(x.kfd, in.kid);
    };
    x.gens.deinit(x.gpa);
    x.disabled.deinit(x.gpa);
    x.gpa.free(x.table);
    x.gpa.free(x.inputs);
    _ = linux.close(x.pmfd);
    _ = linux.close(x.uffd);
    sc.sinty_compute_close(x.kfd);
    x.gpa.destroy(x);
}

pub export fn sinty_compute_ctx_set_verify(c: *Ctx, every: u32) void {
    c.lock.lock();
    defer c.lock.unlock();
    c.verify_every = if (every == 0) 1 else every;
}

pub export fn sinty_compute_input(c: *Ctx, addr: ?*const anyopaque, len: usize, handle: *u32) c_int {
    if (len == 0) return EINVAL;
    const a = @intFromPtr(addr);
    const start = std.mem.alignBackward(usize, a, PAGE);
    const end = std.mem.alignForward(usize, a + len, PAGE);
    c.lock.lock();
    defer c.lock.unlock();
    var slot: ?u32 = null;
    for (c.inputs[0..c.n_inputs], 0..) |in, i| if (!in.live) {
        slot = @intCast(i);
        break;
    };
    if (slot == null) {
        if (c.n_inputs >= MAX_INPUTS) return ENOSPC;
        slot = c.n_inputs;
        c.n_inputs += 1;
    }
    var reg: UffdRegister = .{ .range = .{ .start = start, .len = end - start }, .mode = UFFDIO_REGISTER_MODE_WP, .ioctls = 0 };
    const r = linux.ioctl(c.uffd, UFFDIO_REGISTER, @intFromPtr(&reg));
    if (!ok(r)) {
        if (slot.? + 1 == c.n_inputs) c.n_inputs -= 1;
        return err(r);
    }
    const p = protect(c, start, end);
    if (p != 0) return p;
    var kid: u64 = 0;
    const t = sc.sinty_compute_track(c.kfd, @ptrFromInt(start), end - start, &kid);
    if (t != 0) return t;
    c.inputs[slot.?] = .{ .start = start, .end = end, .kid = kid, .writes = 0, .live = true };
    handle.* = slot.?;
    return 0;
}

pub export fn sinty_compute_input_drop(c: *Ctx, handle: u32) c_int {
    c.lock.lock();
    defer c.lock.unlock();
    if (handle >= c.n_inputs or !c.inputs[handle].live) return ENOENT;
    const in = &c.inputs[handle];
    in.live = false;
    _ = sc.sinty_compute_untrack(c.kfd, in.kid);
    var shared = false;
    for (c.inputs[0..c.n_inputs]) |o| if (o.live and o.start < in.end and in.start < o.end) {
        shared = true;
    };
    if (!shared) {
        var range: UffdRange = .{ .start = in.start, .len = in.end - in.start };
        _ = linux.ioctl(c.uffd, UFFDIO_UNREGISTER, @intFromPtr(&range));
    }
    var it = c.head;
    while (it) |e| {
        it = e.next;
        for (e.gens) |g| if (g.input == handle) {
            destroy(c, e);
            break;
        };
    }
    return 0;
}

pub export fn sinty_compute_call(
    c: *Ctx,
    region: u32,
    key: ?*const anyopaque,
    key_len: usize,
    inputs: ?[*]const u32,
    n_inputs: usize,
    out: ?*anyopaque,
    out_len: usize,
    func: Fn,
    arg: ?*anyopaque,
) c_int {
    const t0 = now();
    c.lock.lock();
    const s = refreshState(c);
    const mode = s & 0xff;
    if (s & 0x100 == 0 or isDisabled(c, region)) {
        c.lock.unlock();
        return func(arg, out, out_len);
    }
    const k: []const u8 = if (key) |p| @as([*]const u8, @ptrCast(p))[0..key_len] else &.{};
    const ids: []const u32 = if (inputs) |p| p[0..n_inputs] else &.{};
    const o: []u8 = if (out) |p| @as([*]u8, @ptrCast(p))[0..out_len] else &.{};
    const hash = std.hash.Wyhash.hash(region, k);
    c.calls +%= 1;
    if (c.calls % REPORT_EVERY == 0) flushReport(c);
    if (!snapshot(c, ids)) {
        c.lock.unlock();
        return func(arg, out, out_len);
    }
    if (find(c, region, hash, k)) |e| {
        if (fresh(c, e) and e.out.len == out_len) {
            c.pending.hits += 1;
            c.total.hits += 1;
            if (mode == sc.SINTY_COMPUTE_MEASURE) {
                c.pending.spent_ns += now() - t0;
                c.lock.unlock();
                return func(arg, out, out_len);
            }
            var check = mode == sc.SINTY_COMPUTE_VERIFY;
            if (check) {
                c.verify_tick +%= 1;
                check = c.verify_tick % c.verify_every == 0;
            }
            if (!check) {
                @memcpy(o, e.out);
                unlink(c, e);
                pushFront(c, e);
                c.pending.saved_ns += e.cost_ns;
                c.total.saved_ns += e.cost_ns;
                c.pending.spent_ns += now() - t0;
                c.lock.unlock();
                return 0;
            }
            const want = c.gpa.dupe(u8, e.out) catch {
                c.lock.unlock();
                return func(arg, out, out_len);
            };
            defer c.gpa.free(want);
            c.pending.spent_ns += now() - t0;
            c.lock.unlock();
            const r = func(arg, out, out_len);
            c.lock.lock();
            defer c.lock.unlock();
            c.pending.verified += 1;
            c.total.verified += 1;
            if (r == 0 and !std.mem.eql(u8, want, o)) {
                c.pending.mismatches += 1;
                c.total.mismatches += 1;
                dropRegion(c, region);
                c.disabled.append(c.gpa, region) catch {};
                flushReport(c);
            }
            return r;
        }
        destroy(c, e);
    }
    const gens_ok = c.gens.items.len == ids.len;
    c.lock.unlock();
    const t1 = now();
    const r = func(arg, out, out_len);
    const cost = now() - t1;
    c.lock.lock();
    defer c.lock.unlock();
    c.pending.misses += 1;
    c.total.misses += 1;
    c.pending.spent_ns += t1 - t0;
    if (r == 0 and gens_ok and find(c, region, hash, k) == null) store(c, region, hash, k, o, cost);
    return r;
}

pub export fn sinty_compute_ctx_report(c: *Ctx, report: *sc.Report) void {
    c.lock.lock();
    defer c.lock.unlock();
    flushReport(c);
    report.* = c.total;
}

pub export fn sinty_compute_ctx_used(c: *Ctx) usize {
    c.lock.lock();
    defer c.lock.unlock();
    return c.used;
}

test "uffd and pagemap ioctl numbers match the kernel headers" {
    try std.testing.expectEqual(@as(u32, 0xc018aa3f), UFFDIO_API);
    try std.testing.expectEqual(@as(u32, 0xc020aa00), UFFDIO_REGISTER);
    try std.testing.expectEqual(@as(u32, 0x8010aa01), UFFDIO_UNREGISTER);
    try std.testing.expectEqual(@as(u32, 0xc018aa06), UFFDIO_WRITEPROTECT);
    try std.testing.expectEqual(@as(u32, 0xc0606610), PAGEMAP_SCAN);
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(PmScanArg));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(PageRegion));
}
