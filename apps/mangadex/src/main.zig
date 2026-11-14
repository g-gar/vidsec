const std = @import("std");
const flowdata = @import("flowdata");
const ds_memory = @import("flowdata_datasource_memory");
const ds_file_store = @import("flowdata_datasource_file_store");
const ds_sqlite = @import("flowdata_datasource_sqlite");
const ds_yaml = @import("flowdata_datasource_yaml");
const ds_ssh_store = @import("flowdata_datasource_ssh_store");
const inbound_cli = @import("flowdata_ext_inbound_cli");
const inbound_http = @import("flowdata_ext_inbound_http");
const inbound_grpc = @import("flowdata_ext_inbound_grpc");
const trace_jsonl = @import("flowdata_ext_trace_jsonl");
const opentelemetry = @import("flowdata_ext_opentelemetry");
const dag_viz = @import("flowdata_ext_dag_viz");

fn registerMangaDexDrivers(registry: *flowdata.RepositoryRegistry) anyerror!void {
    try registry.registerDriver("memory", &ds_memory.MemoryRepository.createHeap);
    try registry.registerDriver("file_store", &ds_file_store.FileStoreRepository.createHeap);
    try registry.registerDriver("sqlite", &ds_sqlite.SqliteRepository.createHeap);
    try registry.registerDriver("yaml", &ds_yaml.YamlFileRepository.createHeap);
    try registry.registerDriver("yaml_file", &ds_yaml.YamlFileRepository.createHeap);
    try registry.registerDriver("ssh_store", &ds_ssh_store.SshStoreRepository.createHeap);
}

pub fn main(init: std.process.Init) !u8 {
    return flowdata.HostApp.runCliEntry(init, .{
        .app_name = "mangadex",
        .description = "MangaDex Declarative Catalog Pipeline & Ingestion Engine",
        .version = "0.1.0",
        .driver_initializer = &registerMangaDexDrivers,
        .extensions = &.{
            inbound_cli.extension,
            inbound_http.extension,
            inbound_grpc.extension,
            trace_jsonl.extension,
            opentelemetry.extension,
            dag_viz.extension,
        },
    });
}
