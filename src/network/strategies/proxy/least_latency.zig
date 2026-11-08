const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");
const ProxySelectorStrategy = contracts.ProxySelectorStrategy;
const ProxyEndpointState = contracts.ProxyEndpointState;
const CircuitBreakerConfig = contracts.CircuitBreakerConfig;

/// EWMA Least-Latency proxy selector strategy (`least_latency`).
pub const LeastLatencyEwmaStrategy = struct {
    comptime {
        ProxySelectorStrategy.assertImplements(@This());
    }

    dummy: u8 = 0,

    pub fn createHeap(allocator: Allocator) !ProxySelectorStrategy {
        const self = try allocator.create(LeastLatencyEwmaStrategy);
        self.* = .{};
        return self.proxySelectorStrategy();
    }

    pub fn select(
        _: *LeastLatencyEwmaStrategy,
        endpoints: []ProxyEndpointState,
        cb: CircuitBreakerConfig,
        _: []const u8,
        now_ms: u64,
    ) ?usize {
        var best_idx: ?usize = null;
        var best_lat: f64 = std.math.inf(f64);

        for (endpoints, 0..) |*st, i| {
            if (!st.isAvailable(now_ms, cb.cooldown_ms)) continue;
            if (best_idx == null or st.ewma_latency_ms < best_lat) {
                best_lat = st.ewma_latency_ms;
                best_idx = i;
            }
        }
        return best_idx;
    }

    pub fn proxySelectorStrategy(self: *LeastLatencyEwmaStrategy) ProxySelectorStrategy {
        const Trampoline = struct {
            fn doSelect(
                ctx: *anyopaque,
                endpoints: []ProxyEndpointState,
                cb: CircuitBreakerConfig,
                dst_host: []const u8,
                now_ms: u64,
            ) ?usize {
                const s: *LeastLatencyEwmaStrategy = @ptrCast(@alignCast(ctx));
                return s.select(endpoints, cb, dst_host, now_ms);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *LeastLatencyEwmaStrategy = @ptrCast(@alignCast(ctx));
                allocator.destroy(s);
            }

            const vtable = ProxySelectorStrategy.VTable{
                .select = &doSelect,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
