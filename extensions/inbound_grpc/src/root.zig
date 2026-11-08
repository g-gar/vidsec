const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const KernelContext = flowdata.kernel.KernelContext;
const Extension = flowdata.kernel.Extension;
const InboundTransport = flowdata.transport.inbound.InboundTransport;
const InboundTransportConfig = flowdata.transport.inbound.InboundTransportConfig;

pub const grpc_transport = @import("grpc_transport.zig");
pub const GrpcTransport = grpc_transport.GrpcTransport;

pub fn createDaemon(allocator: Allocator, config: InboundTransportConfig) anyerror!InboundTransport {
    return GrpcTransport.createDaemon(allocator, config);
}

pub const extension = Extension.fromStateless("flowdata.inbound.grpc", struct {
    fn reg(k: *KernelContext) anyerror!void {
        try k.inbound.register("grpc", &createDaemon);
    }
}.reg);
