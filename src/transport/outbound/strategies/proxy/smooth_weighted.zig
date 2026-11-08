const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");
const ProxySelectorStrategy = contracts.ProxySelectorStrategy;
const ProxyEndpointState = contracts.ProxyEndpointState;
const CircuitBreakerConfig = contracts.CircuitBreakerConfig;

/// Nginx-style Smooth Weighted Round-Robin proxy selector strategy (`weighted`).
pub const SmoothWeightedStrategy = struct {
    comptime {
        ProxySelectorStrategy.assertImplements(@This());
    }

    dummy: u8 = 0,

    pub fn createHeap(allocator: Allocator) !ProxySelectorStrategy {
        const self = try allocator.create(SmoothWeightedStrategy);
        self.* = .{};
        return self.proxySelectorStrategy();
    }

    pub fn select(
        _: *SmoothWeightedStrategy,
        endpoints: []ProxyEndpointState,
        cb: CircuitBreakerConfig,
        _: []const u8,
        now_ms: u64,
    ) ?usize {
        var total_weight: i64 = 0;
        var best_idx: ?usize = null;
        var best_cw: i64 = std.math.minInt(i64);

        for (endpoints, 0..) |*st, i| {
            if (!st.isAvailable(now_ms, cb.cooldown_ms)) continue;
            const w: i64 = @intCast(@max(st.spec.weight, 1));
            st.current_weight += w;
            total_weight += w;
            if (best_idx == null or st.current_weight > best_cw) {
                best_cw = st.current_weight;
                best_idx = i;
            }
        }

        if (best_idx) |idx| {
            endpoints[idx].current_weight -= total_weight;
            return idx;
        }
        return null;
    }

    pub fn proxySelectorStrategy(self: *SmoothWeightedStrategy) ProxySelectorStrategy {
        const Trampoline = struct {
            fn doSelect(
                ctx: *anyopaque,
                endpoints: []ProxyEndpointState,
                cb: CircuitBreakerConfig,
                dst_host: []const u8,
                now_ms: u64,
            ) ?usize {
                const s: *SmoothWeightedStrategy = @ptrCast(@alignCast(ctx));
                return s.select(endpoints, cb, dst_host, now_ms);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *SmoothWeightedStrategy = @ptrCast(@alignCast(ctx));
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
