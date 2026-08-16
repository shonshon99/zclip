const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // translate-c over a shim header that includes <sqlite3.h>; `@cImport` in
    // source is deprecated in 0.16. Add new SQLite symbols by editing the shim.
    const sqlite_c = b.addTranslateC(.{
        .root_source_file = b.path("src/sqlite_c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("sqlite_c", sqlite_c.createModule());
    const zig_objc = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("objc", zig_objc.module("objc"));
    root_mod.linkSystemLibrary("sqlite3", .{});
    root_mod.linkFramework("Foundation", .{});
    root_mod.linkFramework("AppKit", .{});
    // These resolve the symbols src/image.zig declares by hand.
    root_mod.linkFramework("CoreFoundation", .{});
    root_mod.linkFramework("CoreGraphics", .{});
    root_mod.linkFramework("ImageIO", .{});

    const exe = b.addExecutable(.{
        .name = "zclip",
        .root_module = root_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zclip");
    run_step.dependOn(&run_cmd.step);
}
