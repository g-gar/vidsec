const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Pure standalone MangaDex SDK module (ZERO imports of Flowdata)
    const sdk_mod = b.addModule("mangadex_sdk", .{
        .root_source_file = b.path("lib/mangadex_sdk/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 1b. Pure standalone Komga SDK module (ZERO imports of Flowdata)
    const komga_sdk_mod = b.addModule("komga_sdk", .{
        .root_source_file = b.path("lib/komga_sdk/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 1c. Pure standalone ZIP & CBZ module
    const zip_cflags = &.{ "-std=c99", "-O3", "-D_GNU_SOURCE" };
    const zip_archive_mod = b.addModule("zip_archive", .{
        .root_source_file = b.path("lib/zip_archive/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zip_archive_mod.addIncludePath(b.path("lib/zip_archive/c"));
    zip_archive_mod.addCSourceFile(.{
        .file = b.path("lib/zip_archive/c/miniz.c"),
        .flags = zip_cflags,
    });

    // 1d. Pure standalone ComicInfo XML metadata module (ZERO external dependencies)
    const comicinfo_mod = b.addModule("comicinfo", .{
        .root_source_file = b.path("lib/comicinfo/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Multi-source abstraction module
    const sources_mod = b.addModule("sources", .{
        .root_source_file = b.path("lib/sources/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    sources_mod.addImport("mangadex_sdk", sdk_mod);

    // 3. Flowdata Core Engine dependency
    const flowdata_dep = b.dependency("flowdata", .{
        .target = target,
        .optimize = optimize,
    });
    const flowdata_mod = flowdata_dep.module("flowdata");
    const extensions_mod = flowdata_dep.module("flowdata_extensions");

    // 4. App module (combining Flowdata, Adapters, Config, and SDK)
    const app_mod = b.addModule("mangadex_app", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_mod.addImport("flowdata", flowdata_mod);
    app_mod.addImport("mangadex_sdk", sdk_mod);
    app_mod.addImport("komga_sdk", komga_sdk_mod);
    app_mod.addImport("zip_archive", zip_archive_mod);
    app_mod.addImport("comicinfo", comicinfo_mod);
    app_mod.addImport("sources", sources_mod);

    // 5. Plugin module
    const plugin_mod = b.addModule("mangadex_plugin", .{
        .root_source_file = b.path("plugin/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_mod.addImport("flowdata", flowdata_mod);
    plugin_mod.addImport("mangadex_sdk", sdk_mod);
    plugin_mod.addImport("komga_sdk", komga_sdk_mod);
    plugin_mod.addImport("zip_archive", zip_archive_mod);
    plugin_mod.addImport("comicinfo", comicinfo_mod);
    plugin_mod.addImport("sources", sources_mod);
    plugin_mod.addImport("mangadex_app", app_mod);

    // 5b. Standalone shared library plugin (`libmanga_catalog.so`)
    const catalog_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "manga_catalog",
        .root_module = plugin_mod,
    });
    b.installArtifact(catalog_lib);

    // 6. MangaDex CLI / Application Executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("mangadex_app", app_mod);
    exe_mod.addImport("mangadex_sdk", sdk_mod);
    exe_mod.addImport("komga_sdk", komga_sdk_mod);
    exe_mod.addImport("zip_archive", zip_archive_mod);
    exe_mod.addImport("comicinfo", comicinfo_mod);
    exe_mod.addImport("sources", sources_mod);
    exe_mod.addImport("flowdata", flowdata_mod);
    exe_mod.addImport("flowdata_extensions", extensions_mod);
    exe_mod.addImport("mangadex_plugin", plugin_mod);
    exe_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "mangadex",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // 7. Test suite
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("mangadex_sdk", sdk_mod);
    test_mod.addImport("komga_sdk", komga_sdk_mod);
    test_mod.addImport("zip_archive", zip_archive_mod);
    test_mod.addImport("comicinfo", comicinfo_mod);
    test_mod.addImport("sources", sources_mod);
    test_mod.addImport("flowdata", flowdata_mod);
    test_mod.addImport("flowdata_extensions", extensions_mod);
    test_mod.addImport("mangadex_app", app_mod);
    test_mod.addImport("mangadex_plugin", plugin_mod);
    test_mod.linkSystemLibrary("sqlite3", .{});

    const test_artifact = b.addTest(.{
        .root_module = test_mod,
    });
    const run_test = b.addRunArtifact(test_artifact);
    run_test.setCwd(b.path("."));

    const test_step = b.step("test", "Run MangaDex test suite");
    test_step.dependOn(&run_test.step);
}
