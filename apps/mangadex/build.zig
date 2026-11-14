const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Flowdata Core Engine & Shared Libraries dependency
    const flowdata_dep = b.dependency("flowdata", .{
        .target = target,
        .optimize = optimize,
    });
    const flowdata_mod = flowdata_dep.module("flowdata");
    const sdk_mod = flowdata_dep.module("flowdata_mangadex");
    const komga_sdk_mod = flowdata_dep.module("flowdata_komga");
    const zip_archive_mod = flowdata_dep.module("flowdata_zip_archive");
    const comicinfo_mod = flowdata_dep.module("flowdata_comicinfo");

    // 2. Declarative Datasource Drivers & Extensions
    const ds_memory_mod = flowdata_dep.module("flowdata_datasource_memory");
    const ds_file_store_mod = flowdata_dep.module("flowdata_datasource_file_store");
    const ds_sqlite_mod = flowdata_dep.module("flowdata_datasource_sqlite");
    const ds_yaml_mod = flowdata_dep.module("flowdata_datasource_yaml");
    const ds_ssh_store_mod = flowdata_dep.module("flowdata_datasource_ssh_store");
    const ext_inbound_cli_mod = flowdata_dep.module("flowdata_ext_inbound_cli");
    const ext_inbound_http_mod = flowdata_dep.module("flowdata_ext_inbound_http");
    const ext_inbound_grpc_mod = flowdata_dep.module("flowdata_ext_inbound_grpc");
    const ext_trace_jsonl_mod = flowdata_dep.module("flowdata_ext_trace_jsonl");
    const ext_opentelemetry_mod = flowdata_dep.module("flowdata_ext_opentelemetry");
    const ext_dag_viz_mod = flowdata_dep.module("flowdata_ext_dag_viz");

    // 3. Unified App module (`src/root.zig`: Adapters, Config, Sources, Container, Tasks, Catalog)
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

    // 4. Standalone shared library plugin (`libmanga_catalog.so`)
    const plugin_entry_mod = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_entry_mod.addImport("flowdata", flowdata_mod);
    plugin_entry_mod.addImport("mangadex_app", app_mod);

    const catalog_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "manga_catalog",
        .root_module = plugin_entry_mod,
    });
    b.installArtifact(catalog_lib);

    // 5. MangaDex CLI / Application Executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("mangadex_app", app_mod);
    exe_mod.addImport("flowdata", flowdata_mod);
    exe_mod.addImport("flowdata_datasource_memory", ds_memory_mod);
    exe_mod.addImport("flowdata_datasource_file_store", ds_file_store_mod);
    exe_mod.addImport("flowdata_datasource_sqlite", ds_sqlite_mod);
    exe_mod.addImport("flowdata_datasource_yaml", ds_yaml_mod);
    exe_mod.addImport("flowdata_datasource_ssh_store", ds_ssh_store_mod);
    exe_mod.addImport("flowdata_ext_inbound_cli", ext_inbound_cli_mod);
    exe_mod.addImport("flowdata_ext_inbound_http", ext_inbound_http_mod);
    exe_mod.addImport("flowdata_ext_inbound_grpc", ext_inbound_grpc_mod);
    exe_mod.addImport("flowdata_ext_trace_jsonl", ext_trace_jsonl_mod);
    exe_mod.addImport("flowdata_ext_opentelemetry", ext_opentelemetry_mod);
    exe_mod.addImport("flowdata_ext_dag_viz", ext_dag_viz_mod);

    const exe = b.addExecutable(.{
        .name = "mangadex",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // 6. Test suite
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
    test_mod.addImport("flowdata", flowdata_mod);
    test_mod.addImport("flowdata_datasource_sqlite", ds_sqlite_mod);
    test_mod.addImport("mangadex_app", app_mod);

    const test_artifact = b.addTest(.{
        .root_module = test_mod,
    });
    const run_test = b.addRunArtifact(test_artifact);
    run_test.setCwd(b.path("."));

    const test_step = b.step("test", "Run MangaDex test suite");
    test_step.dependOn(&run_test.step);
}
