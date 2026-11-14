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

    // Flowdata Dependency from root
    const flowdata_dep = b.dependency("flowdata", .{
        .target = target,
        .optimize = optimize,
    });
    const flowdata_mod = flowdata_dep.module("flowdata");
    const abi_mod = flowdata_dep.module("flowdata_abi");
    const dataflow_mod = flowdata_dep.module("flowdata_dataflow");
    const ds_memory_mod = flowdata_dep.module("flowdata_datasource_memory");
    const ds_file_store_mod = flowdata_dep.module("flowdata_datasource_file_store");
    const ds_sqlite_mod = flowdata_dep.module("flowdata_datasource_sqlite");
    const ext_artifact_mod = flowdata_dep.module("flowdata_ext_artifact");
    const ext_inbound_cli_mod = flowdata_dep.module("flowdata_ext_inbound_cli");
    const ext_inbound_http_mod = flowdata_dep.module("flowdata_ext_inbound_http");
    const ext_inbound_grpc_mod = flowdata_dep.module("flowdata_ext_inbound_grpc");
    const media_ir_mod = flowdata_dep.module("media_ir");
    const isobmff_mod = flowdata_dep.module("isobmff");
    const ebml_mod = flowdata_dep.module("ebml");
    const riff_mod = flowdata_dep.module("riff");
    const tika_mod = flowdata_dep.module("tika");

    // 2. Vidsec forensic magic scanner & triage helpers (`src/magic/mod.zig`)
    const magic_mod = b.addModule("vidsec_magic", .{
        .root_source_file = b.path("src/magic/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    magic_mod.addImport("tika", tika_mod);

    // 3. Standalone zero-allocation Math, Shannon Entropy, Statistics, Intervals & Matrix module (`src/math/mod.zig`)
    const math_mod = b.addModule("vidsec_math", .{
        .root_source_file = b.path("src/math/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 4. Vidsec core framework library module (`src/root.zig`)
    const root_mod = b.addModule("vidsec", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.linkSystemLibrary("sqlite3", .{});
    root_mod.addImport("build_options", options_mod);
    root_mod.addImport("flowdata", flowdata_mod);
    root_mod.addImport("flowdata_ext_artifact", ext_artifact_mod);
    root_mod.addImport("flowdata_abi", abi_mod);
    root_mod.addImport("media_ir", media_ir_mod);
    root_mod.addImport("isobmff", isobmff_mod);
    root_mod.addImport("ebml", ebml_mod);
    root_mod.addImport("riff", riff_mod);
    root_mod.addImport("tika", tika_mod);
    root_mod.addImport("vidsec_magic", magic_mod);
    root_mod.addImport("vidsec_math", math_mod);
    root_mod.addImport("vidsec_dataflow", dataflow_mod);

    // 5. Official `.so` Plugin Shared Library (`src/catalog.zig`)
    _ = addPluginSharedLib(b, target, optimize, vidsec_version, abi_mod, tika_mod, magic_mod, math_mod, media_ir_mod, isobmff_mod, ebml_mod, riff_mod, "analyzer", "src/catalog.zig");

    // 6. Main CLI executable (`vidsec`)
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("build_options", options_mod);
    exe_mod.addImport("vidsec", root_mod);
    exe_mod.addImport("flowdata", flowdata_mod);
    exe_mod.addImport("flowdata_abi", abi_mod);
    exe_mod.addImport("flowdata_datasource_memory", ds_memory_mod);
    exe_mod.addImport("flowdata_datasource_file_store", ds_file_store_mod);
    exe_mod.addImport("flowdata_datasource_sqlite", ds_sqlite_mod);
    exe_mod.addImport("flowdata_ext_inbound_cli", ext_inbound_cli_mod);
    exe_mod.addImport("flowdata_ext_inbound_http", ext_inbound_http_mod);
    exe_mod.addImport("flowdata_ext_inbound_grpc", ext_inbound_grpc_mod);
    exe_mod.addImport("tika", tika_mod);
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
    test_suite_mod.addImport("flowdata_abi", abi_mod);
    test_suite_mod.addImport("tika", tika_mod);
    test_suite_mod.addImport("vidsec_magic", magic_mod);
    test_suite_mod.addImport("vidsec_math", math_mod);
    test_suite_mod.addImport("media_ir", media_ir_mod);
    test_suite_mod.addImport("isobmff", isobmff_mod);
    test_suite_mod.addImport("ebml", ebml_mod);
    test_suite_mod.addImport("riff", riff_mod);
    test_suite_mod.addImport("vidsec_dataflow", dataflow_mod);
    test_suite_mod.addImport("flowdata_datasource_memory", ds_memory_mod);
    test_suite_mod.addImport("flowdata_datasource_sqlite", ds_sqlite_mod);

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
    tika_mod: *std.Build.Module,
    magic_mod: *std.Build.Module,
    math_mod: *std.Build.Module,
    media_ir_mod: *std.Build.Module,
    isobmff_mod: *std.Build.Module,
    ebml_mod: *std.Build.Module,
    riff_mod: *std.Build.Module,
    name: []const u8,
    root_source: []const u8,
) *std.Build.Step.Compile {
    const plugin_mod = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_mod.addImport("flowdata_abi", abi_mod);
    plugin_mod.addImport("tika", tika_mod);
    plugin_mod.addImport("vidsec_magic", magic_mod);
    plugin_mod.addImport("vidsec_math", math_mod);
    plugin_mod.addImport("media_ir", media_ir_mod);
    plugin_mod.addImport("isobmff", isobmff_mod);
    plugin_mod.addImport("ebml", ebml_mod);
    plugin_mod.addImport("riff", riff_mod);

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
