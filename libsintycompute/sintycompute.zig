const std = @import("std");
const linux = std.os.linux;

pub const ABI: u32 = 1;
const MAGIC: u32 = 0xC5;

pub const Range = extern struct {
    start: u64,
    len: u64,
    id: u64,
};

pub const Generation = extern struct {
    id: u64,
    generation: u64,
};

pub const Report = extern struct {
    hits: u64 = 0,
    misses: u64 = 0,
    verified: u64 = 0,
    mismatches: u64 = 0,
    saved_ns: u64 = 0,
    spent_ns: u64 = 0,
};

const IOC_ABI = linux.IOCTL.IOR(MAGIC, 0, u32);
const IOC_STATE = linux.IOCTL.IOR(MAGIC, 1, u32);
const IOC_ADD_RANGE = linux.IOCTL.IOWR(MAGIC, 2, Range);
const IOC_REMOVE_RANGE = linux.IOCTL.IOW(MAGIC, 3, u64);
const IOC_GENERATION = linux.IOCTL.IOWR(MAGIC, 4, Generation);
const IOC_REPORT = linux.IOCTL.IOW(MAGIC, 5, Report);

const STATE_ENABLED: u32 = 0x100;

pub const SINTY_COMPUTE_MEASURE: u32 = 0;
pub const SINTY_COMPUTE_ACTIVE: u32 = 1;
pub const SINTY_COMPUTE_VERIFY: u32 = 2;

pub const reuse = @import("reuse.zig");

comptime {
    _ = reuse;
}

fn rc(r: usize) c_int {
    const e = linux.errno(r);
    return if (e == .SUCCESS) 0 else -@as(c_int, @intCast(@intFromEnum(e)));
}

fn ioctl(fd: c_int, req: u32, arg: usize) c_int {
    return rc(linux.ioctl(fd, req, arg));
}

pub export fn sinty_compute_open() c_int {
    const r = linux.open("/dev/sinty-compute", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(r) != .SUCCESS) return rc(r);
    const fd: c_int = @intCast(r);
    var abi: u32 = 0;
    if (ioctl(fd, IOC_ABI, @intFromPtr(&abi)) != 0 or abi != ABI) {
        _ = linux.close(fd);
        return -@as(c_int, @intFromEnum(linux.E.PROTO));
    }
    return fd;
}

pub export fn sinty_compute_close(fd: c_int) void {
    if (fd >= 0) _ = linux.close(fd);
}

pub export fn sinty_compute_state(fd: c_int, enabled: ?*c_int, mode: ?*c_int) c_int {
    var s: u32 = 0;
    const r = ioctl(fd, IOC_STATE, @intFromPtr(&s));
    if (r != 0) return r;
    if (enabled) |e| e.* = @intFromBool(s & STATE_ENABLED != 0);
    if (mode) |m| m.* = @intCast(s & 0xff);
    return 0;
}

pub export fn sinty_compute_track(fd: c_int, addr: ?*const anyopaque, len: usize, id: *u64) c_int {
    var r: Range = .{ .start = @intFromPtr(addr), .len = len, .id = 0 };
    const e = ioctl(fd, IOC_ADD_RANGE, @intFromPtr(&r));
    if (e == 0) id.* = r.id;
    return e;
}

pub export fn sinty_compute_untrack(fd: c_int, id: u64) c_int {
    var v = id;
    return ioctl(fd, IOC_REMOVE_RANGE, @intFromPtr(&v));
}

pub export fn sinty_compute_generation(fd: c_int, id: u64, generation: *u64) c_int {
    var g: Generation = .{ .id = id, .generation = 0 };
    const e = ioctl(fd, IOC_GENERATION, @intFromPtr(&g));
    if (e == 0) generation.* = g.generation;
    return e;
}

pub export fn sinty_compute_report(fd: c_int, report: *const Report) c_int {
    return ioctl(fd, IOC_REPORT, @intFromPtr(report));
}

test "ioctl numbers match the kernel header" {
    try std.testing.expectEqual(@as(u32, 0x8004c500), IOC_ABI);
    try std.testing.expectEqual(@as(u32, 0xc018c502), IOC_ADD_RANGE);
    try std.testing.expectEqual(@as(u32, 0x4008c503), IOC_REMOVE_RANGE);
    try std.testing.expectEqual(@as(u32, 0xc010c504), IOC_GENERATION);
    try std.testing.expectEqual(@as(u32, 0x4030c505), IOC_REPORT);
}

test "opening without the module reports an error" {
    const fd = sinty_compute_open();
    if (fd >= 0) {
        sinty_compute_close(fd);
        return error.SkipZigTest;
    }
    try std.testing.expect(fd < 0);
}
