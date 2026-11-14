const std = @import("std");
const vidsec = @import("vidsec");
const flowdata = @import("flowdata");
const ds_memory = @import("flowdata_datasource_memory");
const ds_file_store = @import("flowdata_datasource_file_store");
const ds_sqlite = @import("flowdata_datasource_sqlite");
const inbound_cli = @import("flowdata_ext_inbound_cli");
const inbound_http = @import("flowdata_ext_inbound_http");
const inbound_grpc = @import("flowdata_ext_inbound_grpc");
const build_options = @import("build_options");

fn registerVidsecDrivers(registry: *flowdata.RepositoryRegistry) anyerror!void {
    try registry.registerDriver("memory", &ds_memory.MemoryRepository.createHeap);
    try registry.registerDriver("file_store", &ds_file_store.FileStoreRepository.createHeap);
    try registry.registerDriver("sqlite", &ds_sqlite.SqliteRepository.createHeap);
}

pub fn main(init: std.process.Init) !u8 {
    return flowdata.HostApp.runCliEntry(init, .{
        .app_name = "vidsec",
        .description = "Declarative Multimedia Security & Transformation Engine",
        .version = build_options.version_string,
        .driver_initializer = &registerVidsecDrivers,
        .extensions = &.{
            inbound_cli.extension,
            inbound_http.extension,
            inbound_grpc.extension,
        },
    });
}
