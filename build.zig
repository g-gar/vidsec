const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Core Flowdata Engine module
    const flowdata_mod = b.addModule("flowdata", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // 2. Flowdata ABI module
    const abi_mod = b.addModule("flowdata_abi", .{
        .root_source_file = b.path("src/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_mod.addImport("flowdata", flowdata_mod);

    // 3. Flowdata Dataflow module
    const dataflow_mod = b.addModule("flowdata_dataflow", .{
        .root_source_file = b.path("src/dataflow.zig"),
        .target = target,
        .optimize = optimize,
    });
    dataflow_mod.addImport("flowdata", flowdata_mod);

    // 4. Extensions: Datasource drivers
    const ds_memory_mod = b.addModule("flowdata_datasource_memory", .{
        .root_source_file = b.path("extensions/datasource/memory/src/root.zig"),
        .target = target,
        .optimize = optimize,
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
    extensions_mod.linkSystemLibrary("sqlite3", .{});

    // 5. Tests
    const run_flowdata_unit = b.addRunArtifact(b.addTest(.{ .root_module = flowdata_mod }));
    const run_ds_memory = b.addRunArtifact(b.addTest(.{ .root_module = ds_memory_mod }));
    const run_ds_file_store = b.addRunArtifact(b.addTest(.{ .root_module = ds_file_store_mod }));
    const run_ds_sqlite = b.addRunArtifact(b.addTest(.{ .root_module = ds_sqlite_mod }));

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
    test_suite_mod.addImport("vidsec", vidsec_shim_mod);
    test_suite_mod.addImport("vidsec_abi", abi_mod);
    test_suite_mod.addImport("vidsec_dataflow", dataflow_mod);

    const run_test_suite = b.addRunArtifact(b.addTest(.{ .root_module = test_suite_mod }));
    run_test_suite.setCwd(b.path("."));

    const test_step = b.step("test", "Run Flowdata test suite");
    test_step.dependOn(&run_flowdata_unit.step);
    test_step.dependOn(&run_ds_memory.step);
    test_step.dependOn(&run_ds_file_store.step);
    test_step.dependOn(&run_ds_sqlite.step);
    test_step.dependOn(&run_test_suite.step);
}
