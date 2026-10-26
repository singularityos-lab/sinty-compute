const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("libsintycompute/sintycompute.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    const lib = b.addLibrary(.{
        .name = "sintycompute",
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .root_module = lib_mod,
    });
    lib.installHeader(b.path("libsintycompute/sintycompute.h"), "sintycompute.h");
    b.installArtifact(lib);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cmd/sinty-compute/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("sintycompute", lib_mod);
    b.installArtifact(b.addExecutable(.{ .name = "sinty-compute", .root_module = cli_mod }));

    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("cmd/sinty-computed/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    daemon_mod.addIncludePath(b.path("cmd/sinty-computed"));
    daemon_mod.linkSystemLibrary("gio-2.0", .{});
    const daemon = b.addExecutable(.{ .name = "sinty-computed", .root_module = daemon_mod });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(daemon.getEmittedBin(), .{ .custom = "libexec" }, "sinty-computed").step);

    b.installFile("data/dev.sinty.Compute.conf", "share/dbus-1/system.d/dev.sinty.Compute.conf");
    b.installFile("data/dev.sinty.Compute.service", "share/dbus-1/system-services/dev.sinty.Compute.service");
    b.installFile("data/dev.sinty.compute.policy", "share/polkit-1/actions/dev.sinty.compute.policy");
    b.installFile("data/sinty-computed.service", "lib/systemd/system/sinty-computed.service");

    const test_step = b.step("test", "run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lib_mod })).step);
    const state_mod = b.createModule(.{
        .root_source_file = b.path("cmd/sinty-computed/state.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = state_mod })).step);
}
