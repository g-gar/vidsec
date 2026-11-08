const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const KernelContext = flowdata.kernel.KernelContext;
const Extension = flowdata.kernel.Extension;
const InboundTransport = flowdata.transport.inbound.InboundTransport;
const InboundTransportConfig = flowdata.transport.inbound.InboundTransportConfig;

pub const http_transport = @import("http_transport.zig");
pub const HttpServerTransport = http_transport.HttpServerTransport;
pub const HttpTransport = HttpServerTransport;

pub fn createDaemon(allocator: Allocator, config: InboundTransportConfig) anyerror!InboundTransport {
    return HttpServerTransport.createDaemon(allocator, config);
}

pub const extension = Extension.fromStateless("flowdata.inbound.http", struct {
    fn reg(k: *KernelContext) anyerror!void {
        try k.inbound.register("http", &createDaemon);
    }
}.reg);
