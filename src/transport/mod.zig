const std = @import("std");

pub const common = @import("common/mod.zig");
pub const inbound = @import("inbound/mod.zig");
pub const outbound = @import("outbound/mod.zig");

// Backward compatibility namespaces
pub const host = inbound;
pub const network = outbound;

// Common primitives
pub const PosixSocket = common.PosixSocket;
pub const PosixSocketError = common.PosixSocketError;
pub const Uri = common.Uri;
pub const NetworkTimeouts = common.NetworkTimeouts;

// Inbound Primary Exports
pub const InboundTransport = inbound.InboundTransport;
pub const InboundRegistry = inbound.InboundRegistry;
pub const InboundDispatcher = inbound.InboundDispatcher;
pub const TransportApp = inbound.TransportApp;
pub const InvocationRequest = inbound.InvocationRequest;
pub const InvocationResponse = inbound.InvocationResponse;
pub const InvocationCommand = inbound.InvocationCommand;
pub const OutputFormat = inbound.OutputFormat;
pub const HostTransport = inbound.HostTransport;
pub const HostDispatcher = inbound.HostDispatcher;
pub const HostApp = inbound.HostApp;

// Outbound Primary Exports
pub const OutboundAdapter = outbound.OutboundAdapter;
pub const OutboundRegistry = outbound.OutboundRegistry;
pub const NetworkAdapter = outbound.NetworkAdapter;
pub const NetworkRegistry = outbound.NetworkRegistry;
pub const NetMiddleware = outbound.NetMiddleware;
pub const MiddlewareChain = outbound.MiddlewareChain;
pub const ProtocolTransport = outbound.ProtocolTransport;
pub const TransportRegistry = outbound.TransportRegistry;
pub const PacketSink = outbound.PacketSink;
pub const NetExchange = outbound.NetExchange;
pub const NetResult = outbound.NetResult;
pub const NetError = outbound.NetError;
pub const CapturedExchangeRecord = outbound.CapturedExchangeRecord;
pub const AdapterMetrics = outbound.AdapterMetrics;
pub const NetworkSpec = outbound.NetworkSpec;
pub const AdapterConfig = outbound.AdapterConfig;

test {
    std.testing.refAllDecls(@This());
    _ = inbound;
    _ = outbound;
}
