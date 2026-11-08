const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");
const ProxySelectorStrategy = contracts.ProxySelectorStrategy;
const ProxyEndpointState = contracts.ProxyEndpointState;
const CircuitBreakerConfig = contracts.CircuitBreakerConfig;

/// Deterministic FNV-1a Sticky-Host affinity proxy selector strategy (`sticky_host`).
pub const StickyHostStrategy = struct {
    comptime {
        ProxySelectorStrategy.assertImplements(@This());
    }

    dummy: u8 = 0,

    pub fn createHeap(allocator: Allocator) !ProxySelectorStrategy {
        const self = try allocator.create(StickyHostStrategy);
        self.* = .{};
        return self.proxySelectorStrategy();
    }

    pub fn select(
        _: *StickyHostStrategy,
        endpoints: []ProxyEndpointState,
        cb: CircuitBreakerConfig,
        dst_host: []const u8,
        now_ms: u64,
    ) ?usize {
        const n = endpoints.len;
        if (n == 0) return null;

        const hash = std.hash.Fnv1a_64.hash(dst_host);
        const start_idx: usize = @intCast(hash % n);

        var offset: usize = 0;
        while (offset < n) : (offset += 1) {
            const idx = (start_idx + offset) % n;
            if (endpoints[idx].isAvailable(now_ms, cb.cooldown_ms)) {
                return idx;
            }
        }
        return null;
    }

    pub fn proxySelectorStrategy(self: *StickyHostStrategy) ProxySelectorStrategy {
        const Trampoline = struct {
            fn doSelect(
                ctx: *anyopaque,
                endpoints: []ProxyEndpointState,
                cb: CircuitBreakerConfig,
                dst_host: []const u8,
                now_ms: u64,
            ) ?usize {
                const s: *StickyHostStrategy = @ptrCast(@alignCast(ctx));
                return s.select(endpoints, cb, dst_host, now_ms);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *StickyHostStrategy = @ptrCast(@alignCast(ctx));
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
