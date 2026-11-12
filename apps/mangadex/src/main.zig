const std = @import("std");
const flowdata = @import("flowdata");
const extensions = @import("flowdata_extensions");

pub fn main(init: std.process.Init) !u8 {
    return flowdata.HostApp.runCliEntry(init, .{
        .app_name = "mangadex",
        .description = "MangaDex Declarative Catalog Pipeline & Ingestion Engine",
        .version = "0.1.0",
        .driver_initializer = &extensions.datasources.registerDefaultDrivers,
        .extensions = &.{
            extensions.inbound_cli.extension,
            extensions.inbound_http.extension,
            extensions.inbound_grpc.extension,
            extensions.trace_jsonl.extension,
            extensions.opentelemetry.extension,
            extensions.dag_viz.extension,
        },
    });
}
