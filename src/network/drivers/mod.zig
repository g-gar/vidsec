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

pub const AdapterDriverFactoryFn = *const fn (
    allocator: Allocator,
    config: contracts.AdapterConfig,
    strategy_registry: *const strategies.ProxyStrategyRegistry,
) anyerror!contracts.NetworkAdapter;
