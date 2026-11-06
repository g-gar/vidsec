const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vidsec_version = std.SemanticVersion{ .major = 2, .minor = 0, .patch = 0 };
    const version_str = "2.0.0";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version_string", version_str);
    build_options.addOption(std.SemanticVersion, "version", vidsec_version);
    const options_mod = build_options.createModule();

    // Flowdata General Purpose Dataflow & Pipeline Engine module
    const flowdata_mod = b.addModule("flowdata", .{
        .root_source_file = b.path("packages/flowdata/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // 1. Standalone C-ABI & Plugin SDK module (Flowdata ABI)
    const abi_mod = b.addModule("vidsec_abi", .{
        .root_source_file = b.path("packages/flowdata/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_mod.addImport("flowdata", flowdata_mod);

    // 2. Standalone zero-allocation Magic Number & MIME Type detection module (`src/plugin/magic/mod.zig`)
    const magic_mod = b.addModule("vidsec_magic", .{
        .root_source_file = b.path("src/plugin/magic/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 3. Standalone zero-allocation Math, Shannon Entropy, Statistics, Intervals & Matrix module (`src/plugin/math/mod.zig`)
    const math_mod = b.addModule("vidsec_math", .{
        .root_source_file = b.path("src/plugin/math/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 4. Standalone Video Intermediate Representation module (`src/plugin/ir/mod.zig`)
    const ir_mod = b.addModule("vidsec_ir", .{
        .root_source_file = b.path("src/plugin/ir/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 5. Standalone Common Format Abstractions module (`src/plugin/formats/common/mod.zig`)
    const formats_common_mod = b.addModule("vidsec_formats_common", .{
        .root_source_file = b.path("src/plugin/formats/common/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    formats_common_mod.addImport("vidsec_ir", ir_mod);

    // 6. Standalone ISOBMFF parsing & structural triage module (`src/plugin/formats/isobmff/mod.zig`)
    const isobmff_mod = b.addModule("vidsec_isobmff", .{
        .root_source_file = b.path("src/plugin/formats/isobmff/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    isobmff_mod.addImport("vidsec_formats_common", formats_common_mod);

    // 7. Standalone MP4 inspection, brand & track decoding module (`src/plugin/formats/mp4/mod.zig`)
    const mp4_mod = b.addModule("vidsec_mp4", .{
        .root_source_file = b.path("src/plugin/formats/mp4/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mp4_mod.addImport("vidsec_isobmff", isobmff_mod);

    // 8. Standalone EBML grammar & element hierarchy parsing module (`src/plugin/formats/ebml/mod.zig`)
    const ebml_mod = b.addModule("vidsec_ebml", .{
        .root_source_file = b.path("src/plugin/formats/ebml/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ebml_mod.addImport("vidsec_formats_common", formats_common_mod);

    // 9. Standalone MKV track & cluster inspection module (`src/plugin/formats/mkv/mod.zig`)
    const mkv_mod = b.addModule("vidsec_mkv", .{
        .root_source_file = b.path("src/plugin/formats/mkv/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mkv_mod.addImport("vidsec_ebml", ebml_mod);

    // 10. Standalone RIFF container & chunk hierarchy parsing module (`src/plugin/formats/riff/mod.zig`)
    const riff_mod = b.addModule("vidsec_riff", .{
        .root_source_file = b.path("src/plugin/formats/riff/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    riff_mod.addImport("vidsec_formats_common", formats_common_mod);

    // 11. Standalone Abstract Forensics library module (`src/plugin/forensics/mod.zig`)
    const forensics_mod = b.addModule("vidsec_forensics", .{
        .root_source_file = b.path("src/plugin/forensics/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    forensics_mod.addImport("vidsec_ir", ir_mod);
    forensics_mod.addImport("vidsec_math", math_mod);

    // 12. Flowdata Dataflow Algebra & Stream Execution module
    const dataflow_mod = b.addModule("vidsec_dataflow", .{
        .root_source_file = b.path("packages/flowdata/dataflow.zig"),
        .target = target,
        .optimize = optimize,
    });
    dataflow_mod.addImport("flowdata", flowdata_mod);

    // 13. Independent Flowdata Datasource Extension Modules
    const ds_memory_mod = b.addModule("flowdata_datasource_memory", .{
        .root_source_file = b.path("packages/extensions/datasource/memory/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ds_memory_mod.addImport("flowdata", flowdata_mod);

    const ds_file_store_mod = b.addModule("flowdata_datasource_file_store", .{
        .root_source_file = b.path("packages/extensions/datasource/file_store/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ds_file_store_mod.addImport("flowdata", flowdata_mod);

    const ds_sqlite_mod = b.addModule("flowdata_datasource_sqlite", .{
        .root_source_file = b.path("packages/extensions/datasource/sqlite/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ds_sqlite_mod.addImport("flowdata", flowdata_mod);
    ds_sqlite_mod.linkSystemLibrary("sqlite3", .{});

    const extensions_mod = b.addModule("vidsec_extensions", .{
        .root_source_file = b.path("packages/extensions/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    extensions_mod.addImport("flowdata", flowdata_mod);
    extensions_mod.addImport("flowdata_datasource_memory", ds_memory_mod);
    extensions_mod.addImport("flowdata_datasource_file_store", ds_file_store_mod);
    extensions_mod.addImport("flowdata_datasource_sqlite", ds_sqlite_mod);
    extensions_mod.linkSystemLibrary("sqlite3", .{});

    // 14. Vidsec core framework library module (`src/root.zig`)
    const root_mod = b.addModule("vidsec", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.linkSystemLibrary("sqlite3", .{});
    root_mod.addImport("build_options", options_mod);
    root_mod.addImport("flowdata", flowdata_mod);
    root_mod.addImport("vidsec_extensions", extensions_mod);
    root_mod.addImport("vidsec_abi", abi_mod);
    root_mod.addImport("vidsec_magic", magic_mod);
    root_mod.addImport("vidsec_math", math_mod);
    root_mod.addImport("vidsec_isobmff", isobmff_mod);
    root_mod.addImport("vidsec_mp4", mp4_mod);
    root_mod.addImport("vidsec_ebml", ebml_mod);
    root_mod.addImport("vidsec_mkv", mkv_mod);
    root_mod.addImport("vidsec_riff", riff_mod);
    root_mod.addImport("vidsec_ir", ir_mod);
    root_mod.addImport("vidsec_formats_common", formats_common_mod);
    root_mod.addImport("vidsec_forensics", forensics_mod);
    root_mod.addImport("vidsec_dataflow", dataflow_mod);

    // 10. Official `.so` Plugin Shared Libraries (`src/plugin/*`)
    _ = addPluginSharedLib(b, target, optimize, vidsec_version, abi_mod, magic_mod, math_mod, isobmff_mod, mp4_mod, ebml_mod, mkv_mod, riff_mod, ir_mod, forensics_mod, "analyzer", "src/plugin/analysis/mod.zig");
    _ = addPluginSharedLib(b, target, optimize, vidsec_version, abi_mod, magic_mod, math_mod, isobmff_mod, mp4_mod, ebml_mod, mkv_mod, riff_mod, ir_mod, forensics_mod, "remediation", "src/plugin/remediation/mod.zig");

    // 6. Main CLI executable (`vidsec`)
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("build_options", options_mod);
    exe_mod.addImport("vidsec", root_mod);
    exe_mod.addImport("vidsec_abi", abi_mod);
    exe_mod.addImport("vidsec_magic", magic_mod);
    exe_mod.addImport("vidsec_math", math_mod);

    const exe = b.addExecutable(.{
        .name = "vidsec",
        .version = vidsec_version,
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the vidsec CLI");
    run_step.dependOn(&run_cmd.step);

    // 7. Unit & integration test suite (`zig build test`)
    // 7. Compilation check of all source declarations in `src/` (`root_mod`)
    const unit_check = b.addTest(.{
        .root_module = root_mod,
    });
    const run_unit_check = b.addRunArtifact(unit_check);

    const flowdata_unit_check = b.addTest(.{
        .root_module = flowdata_mod,
    });
    const run_flowdata_unit_check = b.addRunArtifact(flowdata_unit_check);

    // 8. Full test suite in dedicated `tests/` directory
    const test_suite_mod = b.createModule(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_suite_mod.linkSystemLibrary("sqlite3", .{});
    test_suite_mod.addImport("build_options", options_mod);
    test_suite_mod.addImport("vidsec", root_mod);
    test_suite_mod.addImport("flowdata", flowdata_mod);
    test_suite_mod.addImport("vidsec_abi", abi_mod);
    test_suite_mod.addImport("vidsec_magic", magic_mod);
    test_suite_mod.addImport("vidsec_math", math_mod);
    test_suite_mod.addImport("vidsec_formats_common", formats_common_mod);
    test_suite_mod.addImport("vidsec_isobmff", isobmff_mod);
    test_suite_mod.addImport("vidsec_mp4", mp4_mod);
    test_suite_mod.addImport("vidsec_ebml", ebml_mod);
    test_suite_mod.addImport("vidsec_mkv", mkv_mod);
    test_suite_mod.addImport("vidsec_riff", riff_mod);
    test_suite_mod.addImport("vidsec_ir", ir_mod);
    test_suite_mod.addImport("vidsec_forensics", forensics_mod);
    test_suite_mod.addImport("vidsec_dataflow", dataflow_mod);
    test_suite_mod.addImport("vidsec_extensions", extensions_mod);

    const test_suite = b.addTest(.{
        .root_module = test_suite_mod,
    });
    const run_test_suite = b.addRunArtifact(test_suite);
    run_test_suite.setCwd(b.path("."));

    const run_ds_memory_check = b.addRunArtifact(b.addTest(.{ .root_module = ds_memory_mod }));
    const run_ds_file_store_check = b.addRunArtifact(b.addTest(.{ .root_module = ds_file_store_mod }));
    const run_ds_sqlite_check = b.addRunArtifact(b.addTest(.{ .root_module = ds_sqlite_mod }));

    const test_step = b.step("test", "Run all tests in the tests/ suite");
    test_step.dependOn(&run_unit_check.step);
    test_step.dependOn(&run_flowdata_unit_check.step);
    test_step.dependOn(&run_ds_memory_check.step);
    test_step.dependOn(&run_ds_file_store_check.step);
    test_step.dependOn(&run_ds_sqlite_check.step);
    test_step.dependOn(&run_test_suite.step);
}

/// Helper for registering a `.so` plugin shared library in `build.zig`.
pub fn addPluginSharedLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    abi_mod: *std.Build.Module,
    magic_mod: *std.Build.Module,
    math_mod: *std.Build.Module,
    isobmff_mod: ?*std.Build.Module,
    mp4_mod: ?*std.Build.Module,
    ebml_mod: ?*std.Build.Module,
    mkv_mod: ?*std.Build.Module,
    riff_mod: ?*std.Build.Module,
    ir_mod: ?*std.Build.Module,
    forensics_mod: ?*std.Build.Module,
    name: []const u8,
    root_source: []const u8,
) *std.Build.Step.Compile {
    const plugin_mod = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_mod.addImport("vidsec_abi", abi_mod);
    plugin_mod.addImport("vidsec_magic", magic_mod);
    plugin_mod.addImport("vidsec_math", math_mod);
    if (ir_mod) |m| {
        plugin_mod.addImport("vidsec_ir", m);
    }
    if (forensics_mod) |m| {
        plugin_mod.addImport("vidsec_forensics", m);
    }
    if (isobmff_mod) |m| {
        plugin_mod.addImport("vidsec_isobmff", m);
    }
    if (mp4_mod) |m| {
        plugin_mod.addImport("vidsec_mp4", m);
    }
    if (ebml_mod) |m| {
        plugin_mod.addImport("vidsec_ebml", m);
    }
    if (mkv_mod) |m| {
        plugin_mod.addImport("vidsec_mkv", m);
    }
    if (riff_mod) |m| {
        plugin_mod.addImport("vidsec_riff", m);
    }

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = name,
        .version = version,
        .root_module = plugin_mod,
    });

    const install_lib = b.addInstallArtifact(lib, .{});
    const chmod_cmd = b.addSystemCommand(&.{ "chmod", "0755" });
    chmod_cmd.addArg(b.getInstallPath(install_lib.dest_dir.?, install_lib.dest_sub_path));
    chmod_cmd.step.dependOn(&install_lib.step);
    b.getInstallStep().dependOn(&chmod_cmd.step);

    return lib;
}
