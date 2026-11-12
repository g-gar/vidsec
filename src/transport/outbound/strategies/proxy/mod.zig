const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");

pub const round_robin = @import("round_robin.zig");
pub const smooth_weighted = @import("smooth_weighted.zig");
pub const failover = @import("failover.zig");
pub const least_latency = @import("least_latency.zig");
pub const sticky_host = @import("sticky_host.zig");
pub const random = @import("random.zig");

pub const RoundRobinStrategy = round_robin.RoundRobinStrategy;
pub const SmoothWeightedStrategy = smooth_weighted.SmoothWeightedStrategy;
pub const FailoverStrategy = failover.FailoverStrategy;
pub const LeastLatencyEwmaStrategy = least_latency.LeastLatencyEwmaStrategy;
pub const StickyHostStrategy = sticky_host.StickyHostStrategy;
pub const RandomStrategy = random.RandomStrategy;

/// Factory registry mapping strategy names (`"round_robin"`, `"weighted"`, `"failover"`, `"least_latency"`, `"sticky_host"`, `"random"`)
/// to their `ProxySelectorStrategy` constructors without `switch` statements.
pub const ProxyStrategyRegistry = struct {
    allocator: Allocator,
    factories: std.StringHashMapUnmanaged(contracts.ProxyStrategyFactoryFn) = .empty,

    pub fn init(allocator: Allocator) !ProxyStrategyRegistry {
        var reg = ProxyStrategyRegistry{ .allocator = allocator };
        errdefer reg.deinit();
        try reg.registerDefaults();
        return reg;
    }

    pub fn deinit(self: *ProxyStrategyRegistry) void {
        var it = self.factories.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.factories.deinit(self.allocator);
    }

    pub fn register(self: *ProxyStrategyRegistry, name: []const u8, factory: contracts.ProxyStrategyFactoryFn) !void {
        if (!self.factories.contains(name)) {
            const owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned);
            try self.factories.put(self.allocator, owned, factory);
        } else {
            try self.factories.put(self.allocator, name, factory);
        }
    }

    pub fn registerDefaults(self: *ProxyStrategyRegistry) !void {
        try self.register("round_robin", &RoundRobinStrategy.createHeap);
        try self.register("weighted", &SmoothWeightedStrategy.createHeap);
        try self.register("failover", &FailoverStrategy.createHeap);
        try self.register("least_latency", &LeastLatencyEwmaStrategy.createHeap);
        try self.register("sticky_host", &StickyHostStrategy.createHeap);
        try self.register("random", &RandomStrategy.createHeap);
    }

    pub fn instantiate(self: *const ProxyStrategyRegistry, name: []const u8) !contracts.ProxySelectorStrategy {
        const factory = self.factories.get(name) orelse self.factories.get("round_robin").?;
        return try factory(self.allocator);
    }
};

test "ProxySelectorStrategy: polymorphic strategies and CircuitBreaker" {
    const testing = std.testing;
    var reg = try ProxyStrategyRegistry.init(testing.allocator);
    defer reg.deinit();

    var endpoints = [_]contracts.ProxyEndpointState{
        .{ .spec = .{ .url = "socks5://10.0.0.1:9050", .weight = 3, .priority = 1 } },
        .{ .spec = .{ .url = "socks5://10.0.0.2:9050", .weight = 1, .priority = 2 } },
    };
    const cb = contracts.CircuitBreakerConfig{ .failure_threshold = 2, .cooldown_ms = 5000 };

    // 1. Round Robin
    const rr = try reg.instantiate("round_robin");
    defer rr.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 0), rr.select(&endpoints, cb, "api.example.com", 1000));
    try testing.expectEqual(@as(?usize, 1), rr.select(&endpoints, cb, "api.example.com", 1000));
    try testing.expectEqual(@as(?usize, 0), rr.select(&endpoints, cb, "api.example.com", 1000));

    // 2. Smooth Weighted (3:1 over 4 calls)
    const sw = try reg.instantiate("weighted");
    defer sw.deinit(testing.allocator);
    var count0: usize = 0;
    var count1: usize = 0;
    for (0..4) |_| {
        const idx = sw.select(&endpoints, cb, "api.example.com", 1000).?;
        if (idx == 0) count0 += 1 else count1 += 1;
    }
    try testing.expectEqual(@as(usize, 3), count0);
    try testing.expectEqual(@as(usize, 1), count1);

    // 3. Sticky Host
    const sh = try reg.instantiate("sticky_host");
    defer sh.deinit(testing.allocator);
    const h1 = sh.select(&endpoints, cb, "cdn.example.com", 1000).?;
    const h2 = sh.select(&endpoints, cb, "cdn.example.com", 1000).?;
    try testing.expectEqual(h1, h2);
}
