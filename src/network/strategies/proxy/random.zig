const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");
const ProxySelectorStrategy = contracts.ProxySelectorStrategy;
const ProxyEndpointState = contracts.ProxyEndpointState;
const CircuitBreakerConfig = contracts.CircuitBreakerConfig;

/// Xorshift64* Uniform Random proxy selector strategy (`random`).
pub const RandomStrategy = struct {
    comptime {
        ProxySelectorStrategy.assertImplements(@This());
    }

    prng_state: u64 = 0x853c49e6748fea9b,

    pub fn createHeap(allocator: Allocator) !ProxySelectorStrategy {
        const self = try allocator.create(RandomStrategy);
        self.* = .{};
        return self.proxySelectorStrategy();
    }

    pub fn select(
        self: *RandomStrategy,
        endpoints: []ProxyEndpointState,
        cb: CircuitBreakerConfig,
        _: []const u8,
        now_ms: u64,
    ) ?usize {
        const n = endpoints.len;
        if (n == 0) return null;

        var x = self.prng_state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.prng_state = x;
        const r = x *% 0x2545F4914F6CDD1D;
        const start_idx: usize = @intCast(r % n);

        var offset: usize = 0;
        while (offset < n) : (offset += 1) {
            const idx = (start_idx + offset) % n;
            if (endpoints[idx].isAvailable(now_ms, cb.cooldown_ms)) {
                return idx;
            }
        }
        return null;
    }

    pub fn proxySelectorStrategy(self: *RandomStrategy) ProxySelectorStrategy {
        const Trampoline = struct {
            fn doSelect(
                ctx: *anyopaque,
                endpoints: []ProxyEndpointState,
                cb: CircuitBreakerConfig,
                dst_host: []const u8,
                now_ms: u64,
            ) ?usize {
                const s: *RandomStrategy = @ptrCast(@alignCast(ctx));
                return s.select(endpoints, cb, dst_host, now_ms);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *RandomStrategy = @ptrCast(@alignCast(ctx));
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
