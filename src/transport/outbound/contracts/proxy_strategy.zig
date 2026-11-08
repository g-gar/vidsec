const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
pub const ProxyEndpointConfig = config_mod.ProxyEndpointConfig;
pub const CircuitBreakerConfig = config_mod.CircuitBreakerConfig;

pub const CircuitState = enum {
    closed,
    open,
    half_open,
};

/// Mutable health and weight state for a single proxy endpoint in a pool.
pub const ProxyEndpointState = struct {
    spec: ProxyEndpointConfig,
    circuit: CircuitState = .closed,
    consecutive_failures: u32 = 0,
    opened_at_ms: u64 = 0,
    ewma_latency_ms: f64 = 10.0,
    current_weight: i64 = 0,
    active_inflight: usize = 0,

    pub fn isAvailable(self: *ProxyEndpointState, now_ms: u64, cooldown_ms: u64) bool {
        if (self.spec.max_inflight > 0 and self.active_inflight >= self.spec.max_inflight) {
            return false;
        }
        return switch (self.circuit) {
            .closed, .half_open => true,
            .open => blk: {
                if (now_ms >= self.opened_at_ms + cooldown_ms) {
                    self.circuit = .half_open;
                    break :blk true;
                }
                break :blk false;
            },
        };
    }
};

/// Polymorphic VTable interface for Proxy Selection Algorithms (`RoundRobin`, `SmoothWeighted`, `Failover`, `LeastLatency`, `StickyHost`, `Random`).
/// Replaces monolithic `switch(strategy)` blocks with composable Strategy implementations.
pub const ProxySelectorStrategy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        select: *const fn (
            ctx: *anyopaque,
            endpoints: []ProxyEndpointState,
            cb: CircuitBreakerConfig,
            dst_host: []const u8,
            now_ms: u64,
        ) ?usize,
        deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub fn select(
        self: ProxySelectorStrategy,
        endpoints: []ProxyEndpointState,
        cb: CircuitBreakerConfig,
        dst_host: []const u8,
        now_ms: u64,
    ) ?usize {
        return self.vtable.select(self.ptr, endpoints, cb, dst_host, now_ms);
    }

    pub fn deinit(self: ProxySelectorStrategy, allocator: Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "proxySelectorStrategy")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn proxySelectorStrategy(*" ++ @typeName(T) ++ ") ProxySelectorStrategy'");
            }
        }
    }
};

pub const ProxyStrategyFactoryFn = *const fn (allocator: Allocator) anyerror!ProxySelectorStrategy;
