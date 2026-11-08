const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");
const ProxySelectorStrategy = contracts.ProxySelectorStrategy;
const ProxyEndpointState = contracts.ProxyEndpointState;
const CircuitBreakerConfig = contracts.CircuitBreakerConfig;

/// Cyclic Round-Robin proxy selector strategy (`round_robin`).
pub const RoundRobinStrategy = struct {
    comptime {
        ProxySelectorStrategy.assertImplements(@This());
    }

    cursor: usize = 0,

    pub fn createHeap(allocator: Allocator) !ProxySelectorStrategy {
        const self = try allocator.create(RoundRobinStrategy);
        self.* = .{};
        return self.proxySelectorStrategy();
    }

    pub fn select(
        self: *RoundRobinStrategy,
        endpoints: []ProxyEndpointState,
        cb: CircuitBreakerConfig,
        _: []const u8,
        now_ms: u64,
    ) ?usize {
        const n = endpoints.len;
        if (n == 0) return null;

        var offset: usize = 0;
        while (offset < n) : (offset += 1) {
            const idx = (self.cursor + offset) % n;
            if (endpoints[idx].isAvailable(now_ms, cb.cooldown_ms)) {
                self.cursor = (idx + 1) % n;
                return idx;
            }
        }
        return null;
    }

    pub fn proxySelectorStrategy(self: *RoundRobinStrategy) ProxySelectorStrategy {
        const Trampoline = struct {
            fn doSelect(
                ctx: *anyopaque,
                endpoints: []ProxyEndpointState,
                cb: CircuitBreakerConfig,
                dst_host: []const u8,
                now_ms: u64,
            ) ?usize {
                const s: *RoundRobinStrategy = @ptrCast(@alignCast(ctx));
                return s.select(endpoints, cb, dst_host, now_ms);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *RoundRobinStrategy = @ptrCast(@alignCast(ctx));
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
