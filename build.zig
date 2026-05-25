const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Run translate-c on a thin shim header that includes <sqlite3.h>.
    // Replaces the deprecated `@cImport` block that used to live in db.zig.
    // `createModule()` makes the result a private module visible only to
    // this package.
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
    // Expose the translated SQLite bindings to Zig source as
    // `@import("sqlite_c")`.
    root_mod.addImport("sqlite_c", sqlite_c.createModule());
    // Link the actual SQLite library so the translated declarations
    // resolve at link time. translate-c only generates *headers* — the
    // linker still needs the .dylib.
    root_mod.linkSystemLibrary("sqlite3", .{});
    root_mod.linkFramework("Foundation", .{});
    root_mod.linkFramework("AppKit", .{});

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
