const std = @import("std");

pub const contracts = @import("contracts/mod.zig");
pub const strategies = @import("strategies/mod.zig");
pub const sinks = @import("sinks/mod.zig");
pub const transports = @import("transports/mod.zig");
pub const middleware = @import("middleware/mod.zig");
pub const drivers = @import("drivers/mod.zig");
pub const registry = @import("registry.zig");

// Core Polymorphic VTable Contracts
pub const NetworkAdapter = contracts.NetworkAdapter;
pub const NetMiddleware = contracts.NetMiddleware;
pub const NextHandler = contracts.NextHandler;
pub const MiddlewareChain = contracts.MiddlewareChain;
pub const ProtocolTransport = contracts.ProtocolTransport;
pub const TransportDispatcher = contracts.TransportDispatcher;
pub const TransportRegistry = contracts.TransportRegistry;
pub const NetworkPolicyRule = contracts.NetworkPolicyRule;
pub const PolicyVerdict = contracts.PolicyVerdict;
pub const ProxySelectorStrategy = contracts.ProxySelectorStrategy;
pub const RateLimitStrategy = contracts.RateLimitStrategy;
pub const DnsResolver = contracts.DnsResolver;
pub const PacketSink = contracts.PacketSink;

// Core Exchange & Config Models
pub const NetworkSpec = contracts.NetworkSpec;
pub const AdapterConfig = contracts.AdapterConfig;
pub const Uri = contracts.Uri;
pub const NetExchange = contracts.NetExchange;
pub const NetResult = contracts.NetResult;
pub const NetError = contracts.NetError;
pub const NetStreamId = contracts.NetStreamId;
pub const CapturedExchangeRecord = contracts.CapturedExchangeRecord;
pub const AdapterMetrics = contracts.AdapterMetrics;
pub const CustomTransportResult = contracts.CustomTransportResult;
pub const CustomTransportFn = contracts.CustomTransportFn;

// IoC Registry
pub const NetworkRegistry = registry.NetworkRegistry;

test {
    std.testing.refAllDecls(@This());
    _ = strategies.policy;
    _ = strategies.proxy;
}
