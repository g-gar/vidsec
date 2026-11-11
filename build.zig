const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Standalone Flowdata Plugin C-ABI & Guest SDK module (zero dependencies)
    const plugin_mod = b.addModule("flowdata_plugin", .{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    b.modules.put(b.allocator, b.dupe("flowdata_abi"), plugin_mod) catch @panic("OOM");

    // 2. Standalone Flowdata Reactive Dataflow module (zero dependencies, zero ABI coupling)
    const dataflow_mod = b.addModule("flowdata_dataflow", .{
        .root_source_file = b.path("src/dataflow.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // 3. Core Flowdata Engine module
    const flowdata_mod = b.addModule("flowdata", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    flowdata_mod.addImport("flowdata_plugin", plugin_mod);
    flowdata_mod.addImport("flowdata_abi", plugin_mod);
    flowdata_mod.addImport("flowdata_dataflow", dataflow_mod);

    // 3b. Flowdata Transport module (flowdata_transport + flowdata_network alias)
    const transport_mod = b.addModule("flowdata_transport", .{
        .root_source_file = b.path("src/transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    transport_mod.addImport("flowdata", flowdata_mod);
    b.modules.put(b.allocator, b.dupe("flowdata_network"), transport_mod) catch @panic("OOM");

    // 4. Extensions: Datasource drivers
    const ds_memory_mod = b.addModule("flowdata_datasource_memory", .{
        .root_source_file = b.path("extensions/datasource/memory/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ds_memory_mod.addImport("flowdata", flowdata_mod);

    const ds_file_store_mod = b.addModule("flowdata_datasource_file_store", .{
        .root_source_file = b.path("extensions/datasource/file_store/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ds_file_store_mod.addImport("flowdata", flowdata_mod);

    const ds_sqlite_mod = b.addModule("flowdata_datasource_sqlite", .{
        .root_source_file = b.path("extensions/datasource/sqlite/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ds_sqlite_mod.addImport("flowdata", flowdata_mod);
    ds_sqlite_mod.linkSystemLibrary("sqlite3", .{});

    const ds_yaml_file_mod = b.addModule("flowdata_datasource_yaml_file", .{
        .root_source_file = b.path("extensions/datasource/yaml_file/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ds_yaml_file_mod.addImport("flowdata", flowdata_mod);

    const extensions_mod = b.addModule("flowdata_extensions", .{
        .root_source_file = b.path("extensions/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    extensions_mod.addImport("flowdata", flowdata_mod);
    extensions_mod.addImport("flowdata_datasource_memory", ds_memory_mod);
    extensions_mod.addImport("flowdata_datasource_file_store", ds_file_store_mod);
    extensions_mod.addImport("flowdata_datasource_sqlite", ds_sqlite_mod);
    extensions_mod.addImport("flowdata_datasource_yaml_file", ds_yaml_file_mod);
    extensions_mod.linkSystemLibrary("sqlite3", .{});

    // 5. Tests
    const run_abi_unit = b.addRunArtifact(b.addTest(.{ .root_module = plugin_mod }));
    const run_dataflow_unit = b.addRunArtifact(b.addTest(.{ .root_module = dataflow_mod }));
    const run_flowdata_unit = b.addRunArtifact(b.addTest(.{ .root_module = flowdata_mod }));
    const run_ds_memory = b.addRunArtifact(b.addTest(.{ .root_module = ds_memory_mod }));
    const run_ds_file_store = b.addRunArtifact(b.addTest(.{ .root_module = ds_file_store_mod }));
    const run_ds_sqlite = b.addRunArtifact(b.addTest(.{ .root_module = ds_sqlite_mod }));
    const run_ds_yaml_file = b.addRunArtifact(b.addTest(.{ .root_module = ds_yaml_file_mod }));

    const test_suite_mod = b.createModule(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const vidsec_shim_mod = b.createModule(.{
        .root_source_file = b.path("tests/vidsec_shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    vidsec_shim_mod.addImport("flowdata", flowdata_mod);
    vidsec_shim_mod.addImport("flowdata_extensions", extensions_mod);

    test_suite_mod.linkSystemLibrary("sqlite3", .{});
    test_suite_mod.addImport("flowdata", flowdata_mod);
    test_suite_mod.addImport("flowdata_extensions", extensions_mod);
    test_suite_mod.addImport("flowdata_plugin", plugin_mod);
    test_suite_mod.addImport("flowdata_abi", plugin_mod);
    test_suite_mod.addImport("vidsec", vidsec_shim_mod);
    test_suite_mod.addImport("vidsec_dataflow", dataflow_mod);

    const run_test_suite = b.addRunArtifact(b.addTest(.{ .root_module = test_suite_mod }));
    run_test_suite.setCwd(b.path("."));

    const test_step = b.step("test", "Run Flowdata test suite");
    test_step.dependOn(&run_abi_unit.step);
    test_step.dependOn(&run_dataflow_unit.step);
    test_step.dependOn(&run_flowdata_unit.step);
    test_step.dependOn(&run_ds_memory.step);
    test_step.dependOn(&run_ds_file_store.step);
    test_step.dependOn(&run_ds_sqlite.step);
    test_step.dependOn(&run_ds_yaml_file.step);
    test_step.dependOn(&run_test_suite.step);
}
