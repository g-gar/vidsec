const std = @import("std");
pub const transport = @import("transport/mod.zig");

pub const common = transport.common;
pub const inbound = transport.inbound;
pub const outbound = transport.outbound;
pub const host = transport.host;
pub const network = transport.network;

// Common
pub const PosixSocket = transport.PosixSocket;
pub const PosixSocketError = transport.PosixSocketError;
pub const Uri = transport.Uri;
pub const NetworkTimeouts = transport.NetworkTimeouts;

// Inbound
pub const InboundTransport = transport.InboundTransport;
pub const InboundRegistry = transport.InboundRegistry;
pub const InboundDispatcher = transport.InboundDispatcher;
pub const TransportApp = transport.TransportApp;
pub const InvocationRequest = transport.InvocationRequest;
pub const InvocationResponse = transport.InvocationResponse;
pub const InvocationCommand = transport.InvocationCommand;
pub const OutputFormat = transport.OutputFormat;
pub const HostTransport = transport.HostTransport;
pub const HostDispatcher = transport.HostDispatcher;
pub const HostApp = transport.HostApp;

// Outbound
pub const OutboundAdapter = transport.OutboundAdapter;
pub const OutboundRegistry = transport.OutboundRegistry;
pub const NetworkAdapter = transport.NetworkAdapter;
pub const NetworkRegistry = transport.NetworkRegistry;
pub const NetMiddleware = transport.NetMiddleware;
pub const MiddlewareChain = transport.MiddlewareChain;
pub const ProtocolTransport = transport.ProtocolTransport;
pub const TransportRegistry = transport.TransportRegistry;
pub const PacketSink = transport.PacketSink;
pub const NetExchange = transport.NetExchange;
pub const NetResult = transport.NetResult;
pub const NetError = transport.NetError;
pub const CapturedExchangeRecord = transport.CapturedExchangeRecord;
pub const AdapterMetrics = transport.AdapterMetrics;
pub const NetworkSpec = transport.NetworkSpec;
pub const AdapterConfig = transport.AdapterConfig;

test {
    std.testing.refAllDecls(@This());
}
