const std = @import("std");
const flowdata = @import("flowdata");
const KernelContext = flowdata.kernel.KernelContext;

pub const datasource = @import("flowdata_drivers");
pub const datasources = datasource;
pub const artifact = @import("artifact/src/root.zig");
pub const trace_jsonl = @import("trace_jsonl/src/root.zig");
pub const pcapng = @import("pcapng/src/root.zig");
pub const opentelemetry = @import("opentelemetry/src/root.zig");
pub const dag_viz = @import("dag_viz/src/root.zig");
pub const inbound_cli = @import("inbound_cli/src/root.zig");
pub const inbound_http = @import("inbound_http/src/root.zig");
pub const inbound_grpc = @import("inbound_grpc/src/root.zig");

/// Registers all default modular extensions into the Microkernel.
pub fn registerDefaultExtensions(k: *KernelContext) !void {
    try k.use(datasource.extension);
    try k.use(trace_jsonl.extension);
    try k.use(pcapng.extension);
    try k.use(opentelemetry.extension);
    try k.use(dag_viz.extension);
    try k.use(inbound_cli.extension);
    try k.use(inbound_http.extension);
    try k.use(inbound_grpc.extension);
}
