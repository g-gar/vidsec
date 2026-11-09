const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const comicinfo_mod = b.addModule("comicinfo", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/comicinfo_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("comicinfo", comicinfo_mod);

    const test_artifact = b.addTest(.{
        .root_module = test_mod,
    });
    const run_test = b.addRunArtifact(test_artifact);
    const test_step = b.step("test", "Run comicinfo tests");
    test_step.dependOn(&run_test.step);
}
