const std = @import("std");

pub const Mode = enum(u8) { measure, active, verify };

pub const State = struct {
    enabled: bool = false,
    mode: Mode = .measure,

    pub fn parse(text: []const u8) State {
        var s: State = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = std.mem.trim(u8, line[0..eq], " ");
            const v = std.mem.trim(u8, line[eq + 1 ..], " ");
            if (std.mem.eql(u8, k, "enabled")) s.enabled = std.mem.eql(u8, v, "1");
            if (std.mem.eql(u8, k, "mode")) s.mode = modeOf(v) orelse s.mode;
        }
        return s;
    }

    pub fn serialize(s: State, buf: []u8) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "enabled={d}\nmode={s}\n", .{ @intFromBool(s.enabled), modeName(s.mode) }, 0) catch unreachable;
    }
};

pub fn modeName(m: Mode) [:0]const u8 {
    return switch (m) {
        .measure => "measure",
        .active => "active",
        .verify => "verify",
    };
}

pub fn modeOf(name: []const u8) ?Mode {
    return std.meta.stringToEnum(Mode, name);
}

pub fn listsModule(dep: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, dep, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const path = line[0..colon];
        const base = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return false) + 1 ..];
        if (std.mem.startsWith(u8, base, "sinty_compute.ko")) return true;
    }
    return false;
}

test "state survives a round trip" {
    var buf: [64]u8 = undefined;
    const s: State = .{ .enabled = true, .mode = .verify };
    const back = State.parse(s.serialize(&buf));
    try std.testing.expect(back.enabled);
    try std.testing.expectEqual(Mode.verify, back.mode);
}

test "unknown values keep the defaults" {
    const s = State.parse("enabled=yes\nmode=turbo\nnoise\n");
    try std.testing.expect(!s.enabled);
    try std.testing.expectEqual(Mode.measure, s.mode);
}

test "modules.dep entries are matched by file name" {
    try std.testing.expect(listsModule("kernel/fs/x.ko.zst:\nextra/sinty_compute.ko.zst: kernel/a.ko\n"));
    try std.testing.expect(listsModule("updates/sinty_compute.ko:\n"));
    try std.testing.expect(!listsModule("kernel/fs/sinty_compute_other.ko:\n"));
    try std.testing.expect(!listsModule("kernel/drivers/foo.ko:\n"));
}

pub fn localUser(uid: u32) bool {
    return uid == 0 or (uid >= 1000 and uid < 60000);
}

test "only root and regular local users may change the setting" {
    try std.testing.expect(localUser(0));
    try std.testing.expect(localUser(1001));
    try std.testing.expect(!localUser(65534));
    try std.testing.expect(!localUser(105));
}
