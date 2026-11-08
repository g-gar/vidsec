const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const KernelContext = flowdata.kernel.KernelContext;
const Extension = flowdata.kernel.Extension;
const InboundTransport = flowdata.transport.inbound.InboundTransport;
const InboundTransportConfig = flowdata.transport.inbound.InboundTransportConfig;

pub const cli_transport = @import("cli_transport.zig");
pub const CliTransport = cli_transport.CliTransport;

pub fn createDaemon(allocator: Allocator, config: InboundTransportConfig) anyerror!InboundTransport {
    const s = try allocator.create(CliTransport);
    s.* = CliTransport.init(allocator, config.args);
    s.is_heap_allocated = true;
    return s.inboundTransport();
}

pub const extension = Extension.fromStateless("flowdata.inbound.cli", struct {
    fn reg(k: *KernelContext) anyerror!void {
        try k.inbound.register("cli", &createDaemon);
    }
}.reg);
