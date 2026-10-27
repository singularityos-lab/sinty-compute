const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("gio-import.h");
});
const state = @import("state.zig");

const NAME = "dev.sinty.Compute";
const PATH = "/dev/sinty/Compute";
const IFACE = "dev.sinty.Compute1";
const ACTION = "dev.sinty.compute.manage";
const SYSFS = "/sys/kernel/sinty_compute";
const STATE_FILE = "/var/lib/sinty-compute/state";

const XML =
    \\<node>
    \\  <interface name="dev.sinty.Compute1">
    \\    <property name="Installed" type="b" access="read"/>
    \\    <property name="Loaded" type="b" access="read"/>
    \\    <property name="Enabled" type="b" access="read"/>
    \\    <property name="Mode" type="s" access="read"/>
    \\    <method name="SetEnabled"><arg name="enabled" type="b" direction="in"/></method>
    \\    <method name="SetMode"><arg name="mode" type="s" direction="in"/></method>
    \\    <method name="GetStats"><arg name="stats" type="a{sx}" direction="out"/></method>
    \\    <method name="ResetStats"/>
    \\  </interface>
    \\</node>
;

const COUNTERS = [_][:0]const u8{ "contexts", "ranges", "hits", "misses", "verified", "mismatches", "saved_ns", "spent_ns", "invalidations" };

var connection: ?*c.GDBusConnection = null;

fn vt(s: [*:0]const u8) *const c.GVariantType {
    return @ptrCast(s);
}
var current: state.State = .{};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("sinty-computed: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn sysfsPath(name: []const u8, buf: []u8) [*:0]const u8 {
    return (std.fmt.bufPrintSentinel(buf, SYSFS ++ "/{s}", .{name}, 0) catch unreachable).ptr;
}

fn readSys(name: []const u8, buf: []u8) ?[]const u8 {
    var pbuf: [128]u8 = undefined;
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(sysfsPath(name, &pbuf), &contents, &len, null) == 0) return null;
    defer c.g_free(contents);
    const t = std.mem.trim(u8, contents[0..len], " \n");
    if (t.len > buf.len) return null;
    @memcpy(buf[0..t.len], t);
    return buf[0..t.len];
}

fn writeSys(name: []const u8, value: []const u8) bool {
    var pbuf: [128]u8 = undefined;
    const f = std.c.open(sysfsPath(name, &pbuf), .{ .ACCMODE = .WRONLY });
    if (f < 0) return false;
    defer _ = std.c.close(f);
    return std.c.write(f, value.ptr, value.len) == @as(isize, @intCast(value.len));
}

fn loaded() bool {
    return c.g_file_test(SYSFS, c.G_FILE_TEST_IS_DIR) != 0;
}

fn installed() bool {
    var u: c.struct_utsname = undefined;
    if (c.uname(&u) != 0) return false;
    var pbuf: [512]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pbuf, "/lib/modules/{s}/modules.dep", .{std.mem.sliceTo(&u.release, 0)}, 0) catch return false;
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(p.ptr, &contents, &len, null) == 0) return false;
    defer c.g_free(contents);
    return state.listsModule(contents[0..len]);
}

fn modprobe(remove: bool) bool {
    var argv = [_:null]?[*:0]const u8{ "/usr/sbin/modprobe", "-r", "sinty_compute" };
    if (!remove) argv = .{ "/usr/sbin/modprobe", "sinty_compute", null };
    var status: c_int = 0;
    var err: [*c]c.GError = null;
    if (c.g_spawn_sync(null, @ptrCast(@constCast(&argv)), null, c.G_SPAWN_DEFAULT, null, null, null, null, &status, &err) == 0) {
        std.log.warn("modprobe: {s}", .{if (err) |e| std.mem.span(e.*.message) else "failed"});
        c.g_clear_error(&err);
        return false;
    }
    return c.g_spawn_check_wait_status(status, null) != 0;
}

fn save() void {
    var buf: [64]u8 = undefined;
    const text = current.serialize(&buf);
    _ = c.g_mkdir_with_parents("/var/lib/sinty-compute", 0o755);
    _ = c.g_file_set_contents(STATE_FILE, text.ptr, @intCast(text.len), null);
}

fn load() void {
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(STATE_FILE, &contents, &len, null) == 0) return;
    defer c.g_free(contents);
    current = state.State.parse(contents[0..len]);
}

fn apply() bool {
    if (current.enabled) {
        if (!loaded() and !modprobe(false)) return false;
        if (!writeSys("mode", state.modeName(current.mode))) return false;
        return writeSys("enabled", "1");
    }
    if (loaded()) {
        _ = writeSys("enabled", "0");
        if (readCounter("contexts") == 0) _ = modprobe(true);
    }
    return true;
}

fn readCounter(name: []const u8) i64 {
    var buf: [32]u8 = undefined;
    const t = readSys(name, &buf) orelse return 0;
    return std.fmt.parseInt(i64, t, 10) catch 0;
}

fn emitChanged() void {
    const conn = connection orelse return;
    const b = c.g_variant_builder_new(vt("a{sv}"));
    defer c.g_variant_builder_unref(b);
    c.g_variant_builder_add(b, "{sv}", "Loaded", c.g_variant_new_boolean(@intFromBool(loaded())));
    c.g_variant_builder_add(b, "{sv}", "Enabled", c.g_variant_new_boolean(@intFromBool(current.enabled)));
    c.g_variant_builder_add(b, "{sv}", "Mode", c.g_variant_new_string(state.modeName(current.mode).ptr));
    const empty = [_:null]?[*:0]const u8{};
    _ = c.g_dbus_connection_emit_signal(conn, null, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged", c.g_variant_new("(sa{sv}^as)", IFACE, b, &empty), null);
}

const Call = struct {
    invocation: *c.GDBusMethodInvocation,
    method: [:0]u8,
    params: ?*c.GVariant,
};

fn stats(inv: *c.GDBusMethodInvocation) void {
    const b = c.g_variant_builder_new(vt("a{sx}"));
    defer c.g_variant_builder_unref(b);
    if (loaded()) for (COUNTERS) |n| c.g_variant_builder_add(b, "{sx}", n.ptr, @as(i64, readCounter(n)));
    c.g_dbus_method_invocation_return_value(inv, c.g_variant_new("(a{sx})", b));
}

fn run(call: *Call) void {
    const inv = call.invocation;
    const m = call.method;
    if (std.mem.eql(u8, m, "SetEnabled")) {
        var on: c.gboolean = 0;
        c.g_variant_get(call.params, "(b)", &on);
        const before = current;
        current.enabled = on != 0;
        if (!apply()) {
            current = before;
            _ = apply();
            return c.g_dbus_method_invocation_return_dbus_error(inv, "dev.sinty.Compute1.Error.Failed", "The kernel module could not be loaded.");
        }
    } else if (std.mem.eql(u8, m, "SetMode")) {
        var mode: [*c]const u8 = null;
        c.g_variant_get(call.params, "(&s)", &mode);
        current.mode = state.modeOf(std.mem.span(mode)) orelse
            return c.g_dbus_method_invocation_return_dbus_error(inv, "dev.sinty.Compute1.Error.InvalidArgs", "Unknown mode.");
        if (current.enabled and !writeSys("mode", state.modeName(current.mode)))
            return c.g_dbus_method_invocation_return_dbus_error(inv, "dev.sinty.Compute1.Error.Failed", "The mode could not be changed.");
    } else if (std.mem.eql(u8, m, "ResetStats")) {
        if (loaded()) _ = writeSys("reset", "1");
        return c.g_dbus_method_invocation_return_value(inv, null);
    }
    save();
    emitChanged();
    c.g_dbus_method_invocation_return_value(inv, null);
}

fn finish(call: *Call, ok: bool) void {
    defer {
        c.g_object_unref(call.invocation);
        if (call.params) |p| c.g_variant_unref(p);
        c.g_free(call.method.ptr);
        c.g_free(call);
    }
    if (!ok) return c.g_dbus_method_invocation_return_dbus_error(call.invocation, "dev.sinty.Compute1.Error.NotAuthorized", "Not authorized.");
    run(call);
}

fn byUser(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    const reply = c.g_dbus_connection_call_finish(@ptrCast(@alignCast(src)), res, null) orelse return finish(call, false);
    defer c.g_variant_unref(reply);
    var uid: c.guint32 = 0;
    c.g_variant_get(reply, "(u)", &uid);
    finish(call, state.localUser(uid));
}

fn byPolkit(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    var err: [*c]c.GError = null;
    const reply = c.g_dbus_connection_call_finish(@ptrCast(@alignCast(src)), res, &err);
    if (reply == null) {
        const missing = err != null and (c.g_error_matches(err, c.g_dbus_error_quark(), c.G_DBUS_ERROR_SERVICE_UNKNOWN) != 0 or
            c.g_error_matches(err, c.g_dbus_error_quark(), c.G_DBUS_ERROR_NAME_HAS_NO_OWNER) != 0);
        c.g_clear_error(&err);
        if (!missing) return finish(call, false);
        return checkUser(call);
    }
    defer c.g_variant_unref(reply);
    var ok: c.gboolean = 0;
    var challenge: c.gboolean = 0;
    c.g_variant_get(reply, "((bba{ss}))", &ok, &challenge, @as(?*anyopaque, null));
    if (ok == 0 and !sessionTracking()) return checkUser(call);
    finish(call, ok != 0);
}

fn sessionTracking() bool {
    return c.g_file_test("/run/systemd/seats", c.G_FILE_TEST_IS_DIR) != 0;
}

fn checkUser(call: *Call) void {
    const sender = c.g_dbus_method_invocation_get_sender(call.invocation);
    c.g_dbus_connection_call(connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixUser", c.g_variant_new("(s)", sender), vt("(u)"), c.G_DBUS_CALL_FLAGS_NONE, -1, null, byUser, call);
}

fn authorize(inv: *c.GDBusMethodInvocation, method: [*c]const u8, params: ?*c.GVariant) void {
    const call: *Call = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Call))));
    call.* = .{
        .invocation = @ptrCast(@alignCast(c.g_object_ref(inv))),
        .method = std.mem.span(c.g_strdup(method)),
        .params = if (params) |p| c.g_variant_ref(p) else null,
    };
    const subject = c.g_variant_builder_new(vt("a{sv}"));
    defer c.g_variant_builder_unref(subject);
    c.g_variant_builder_add(subject, "{sv}", "name", c.g_variant_new_string(c.g_dbus_method_invocation_get_sender(inv)));
    const details = c.g_variant_builder_new(vt("a{ss}"));
    defer c.g_variant_builder_unref(details);
    const args = c.g_variant_new("((sa{sv})sa{ss}us)", "system-bus-name", subject, ACTION, details, @as(c.guint32, 1), "");
    c.g_dbus_connection_call(connection, "org.freedesktop.PolicyKit1", "/org/freedesktop/PolicyKit1/Authority", "org.freedesktop.PolicyKit1.Authority", "CheckAuthorization", args, vt("((bba{ss}))"), c.G_DBUS_CALL_FLAGS_NO_AUTO_START, 120000, null, byPolkit, call);
}

fn methodCall(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method: [*c]const u8, params: ?*c.GVariant, inv: ?*c.GDBusMethodInvocation, _: c.gpointer) callconv(.c) void {
    const i = inv orelse return;
    if (std.mem.eql(u8, std.mem.span(method), "GetStats")) return stats(i);
    authorize(i, method, params);
}

fn getProperty(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, prop: [*c]const u8, _: [*c][*c]c.GError, _: c.gpointer) callconv(.c) ?*c.GVariant {
    const p = std.mem.span(prop);
    if (std.mem.eql(u8, p, "Installed")) return c.g_variant_new_boolean(@intFromBool(installed()));
    if (std.mem.eql(u8, p, "Loaded")) return c.g_variant_new_boolean(@intFromBool(loaded()));
    if (std.mem.eql(u8, p, "Enabled")) return c.g_variant_new_boolean(@intFromBool(current.enabled and loaded()));
    if (std.mem.eql(u8, p, "Mode")) return c.g_variant_new_string(state.modeName(current.mode).ptr);
    return null;
}

var vtable: c.GDBusInterfaceVTable = undefined;

fn acquired(conn: ?*c.GDBusConnection, _: [*c]const u8, _: c.gpointer) callconv(.c) void {
    connection = conn;
    vtable = std.mem.zeroes(c.GDBusInterfaceVTable);
    vtable.method_call = methodCall;
    vtable.get_property = getProperty;
    var err: [*c]c.GError = null;
    const info = c.g_dbus_node_info_new_for_xml(XML, &err) orelse fatal("{s}", .{err.*.message});
    if (c.g_dbus_connection_register_object(conn, PATH, info.*.interfaces[0], &vtable, null, null, &err) == 0) fatal("{s}", .{err.*.message});
}

fn lost(_: ?*c.GDBusConnection, _: [*c]const u8, data: c.gpointer) callconv(.c) void {
    c.g_main_loop_quit(@ptrCast(@alignCast(data)));
}

pub fn main() void {
    load();
    if (current.enabled and !apply()) std.log.warn("sinty-computed: the kernel module could not be loaded", .{});
    const loop = c.g_main_loop_new(null, 0);
    _ = c.g_bus_own_name(c.G_BUS_TYPE_SYSTEM, NAME, c.G_BUS_NAME_OWNER_FLAGS_NONE, acquired, null, lost, loop, null);
    c.g_main_loop_run(loop);
}

test {
    _ = state;
}
