const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cflags = &.{ "-std=c99", "-O3", "-D_GNU_SOURCE" };

    const zip_archive_mod = b.addModule("zip_archive", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zip_archive_mod.addIncludePath(b.path("c"));
    zip_archive_mod.addCSourceFile(.{
        .file = b.path("c/miniz.c"),
        .flags = cflags,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/zip_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("zip_archive", zip_archive_mod);
    test_mod.addIncludePath(b.path("c"));

    const test_artifact = b.addTest(.{
        .root_module = test_mod,
    });
    const run_test = b.addRunArtifact(test_artifact);
    const test_step = b.step("test", "Run zip_archive tests");
    test_step.dependOn(&run_test.step);
}
