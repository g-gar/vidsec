const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const strategies = @import("../strategies/mod.zig");

pub const isolated_adapter = @import("isolated_adapter.zig");
pub const ingress_only_adapter = @import("ingress_only_adapter.zig");
pub const sinkhole_adapter = @import("sinkhole_adapter.zig");
pub const egress_adapter = @import("egress_adapter.zig");

pub const IsolatedAdapter = isolated_adapter.IsolatedAdapter;
pub const IngressOnlyAdapter = ingress_only_adapter.IngressOnlyAdapter;
pub const SinkholeAdapter = sinkhole_adapter.SinkholeAdapter;
pub const EgressAdapter = egress_adapter.EgressAdapter;

pub const MiddlewareFactoryFn = *const fn (
    allocator: Allocator,
    config: contracts.AdapterConfig,
) anyerror!?contracts.NetMiddleware;

pub const SinkFactoryFn = *const fn (
    allocator: Allocator,
    config: contracts.AdapterConfig,
) anyerror!?contracts.PacketSink;

pub const AdapterDriverContext = struct {
    proxy_strategies: *const strategies.ProxyStrategyRegistry,
    base_transports: *const contracts.TransportRegistry,
    extra_middlewares: []const MiddlewareFactoryFn = &.{},
    extra_sinks: []const SinkFactoryFn = &.{},
};

pub const AdapterDriverFactoryFn = *const fn (
    allocator: Allocator,
    config: contracts.AdapterConfig,
    ctx: AdapterDriverContext,
) anyerror!contracts.NetworkAdapter;
