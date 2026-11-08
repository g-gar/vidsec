const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");
const RateLimitStrategy = contracts.RateLimitStrategy;
const AcquireDecision = contracts.AcquireDecision;
const RateLimitConfig = contracts.RateLimitConfig;
const PoolConfig = contracts.PoolConfig;

/// Dual Token Bucket rate-limiter (`requests_per_second` + `max_bandwidth_mbps`)
/// implementing the polymorphic `RateLimitStrategy` VTable.
pub const DualTokenBucketStrategy = struct {
    comptime {
        RateLimitStrategy.assertImplements(@This());
    }

    spec: RateLimitConfig,
    pool_spec: PoolConfig,

    req_tokens: f64,
    req_capacity: f64,
    bw_bytes_tokens: f64,
    bw_bytes_capacity: f64,
    last_refill_ms: u64,
    cooldown_until_ms: u64 = 0,
    active_inflight_count: usize = 0,

    pub fn init(spec: RateLimitConfig, pool_spec: PoolConfig, now_ms: u64) DualTokenBucketStrategy {
        const req_cap: f64 = if (spec.burst > 0)
            @floatFromInt(spec.burst)
        else if (spec.requests_per_second > 0.0)
            @max(spec.requests_per_second, 1.0)
        else
            0.0;

        const bw_bytes_per_sec: f64 = (spec.max_bandwidth_mbps * 1_000_000.0) / 8.0;
        const bw_cap: f64 = if (bw_bytes_per_sec > 0.0) bw_bytes_per_sec else 0.0;

        return .{
            .spec = spec,
            .pool_spec = pool_spec,
            .req_tokens = req_cap,
            .req_capacity = req_cap,
            .bw_bytes_tokens = bw_cap,
            .bw_bytes_capacity = bw_cap,
            .last_refill_ms = now_ms,
        };
    }

    pub fn createHeap(allocator: Allocator, spec: RateLimitConfig, pool_spec: PoolConfig, now_ms: u64) !RateLimitStrategy {
        const self = try allocator.create(DualTokenBucketStrategy);
        self.* = DualTokenBucketStrategy.init(spec, pool_spec, now_ms);
        return self.rateLimitStrategy();
    }

    pub fn refill(self: *DualTokenBucketStrategy, now_ms: u64) void {
        if (now_ms <= self.last_refill_ms) return;
        const elapsed_sec: f64 = @as(f64, @floatFromInt(now_ms - self.last_refill_ms)) / 1000.0;
        self.last_refill_ms = now_ms;

        if (self.spec.requests_per_second > 0.0) {
            self.req_tokens = @min(self.req_capacity, self.req_tokens + elapsed_sec * self.spec.requests_per_second);
        }
        if (self.spec.max_bandwidth_mbps > 0.0) {
            const bw_bytes_per_sec: f64 = (self.spec.max_bandwidth_mbps * 1_000_000.0) / 8.0;
            self.bw_bytes_tokens = @min(self.bw_bytes_capacity, self.bw_bytes_tokens + elapsed_sec * bw_bytes_per_sec);
        }
    }

    pub fn tryAcquire(self: *DualTokenBucketStrategy, now_ms: u64, payload_bytes: usize) AcquireDecision {
        if (self.spec.respect_retry_after and now_ms < self.cooldown_until_ms) {
            return .rate_limited_retry_after;
        }

        const max_conc = if (self.spec.max_inflight > 0)
            @min(self.spec.max_inflight, self.pool_spec.max_connections)
        else
            self.pool_spec.max_connections;

        if (max_conc > 0 and self.active_inflight_count >= max_conc) {
            return .pool_exhausted;
        }

        self.refill(now_ms);

        if (self.spec.requests_per_second > 0.0 and self.req_tokens < 1.0) {
            return .rate_limited_rps;
        }

        const needed_bytes: f64 = @floatFromInt(payload_bytes);
        if (self.spec.max_bandwidth_mbps > 0.0 and payload_bytes > 0 and self.bw_bytes_tokens < needed_bytes) {
            return .rate_limited_bandwidth;
        }

        if (self.spec.requests_per_second > 0.0) {
            self.req_tokens -= 1.0;
        }
        if (self.spec.max_bandwidth_mbps > 0.0 and payload_bytes > 0) {
            self.bw_bytes_tokens -= needed_bytes;
        }

        self.active_inflight_count += 1;
        return .allowed;
    }

    pub fn releaseInflight(self: *DualTokenBucketStrategy) void {
        if (self.active_inflight_count > 0) {
            self.active_inflight_count -= 1;
        }
    }

    pub fn applyRetryAfter(self: *DualTokenBucketStrategy, now_ms: u64, retry_after_ms: u64) void {
        if (!self.spec.respect_retry_after) return;
        const target = now_ms + retry_after_ms;
        if (target > self.cooldown_until_ms) {
            self.cooldown_until_ms = target;
        }
        self.req_tokens = 0.0;
    }

    pub fn rateLimitStrategy(self: *DualTokenBucketStrategy) RateLimitStrategy {
        const Trampoline = struct {
            fn doTryAcquire(ctx: *anyopaque, now_ms: u64, payload_bytes: usize) AcquireDecision {
                const s: *DualTokenBucketStrategy = @ptrCast(@alignCast(ctx));
                return s.tryAcquire(now_ms, payload_bytes);
            }

            fn doReleaseInflight(ctx: *anyopaque) void {
                const s: *DualTokenBucketStrategy = @ptrCast(@alignCast(ctx));
                s.releaseInflight();
            }

            fn doApplyRetryAfter(ctx: *anyopaque, now_ms: u64, retry_after_ms: u64) void {
                const s: *DualTokenBucketStrategy = @ptrCast(@alignCast(ctx));
                s.applyRetryAfter(now_ms, retry_after_ms);
            }

            fn doActiveInflight(ctx: *const anyopaque) usize {
                const s: *const DualTokenBucketStrategy = @ptrCast(@alignCast(ctx));
                return s.active_inflight_count;
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *DualTokenBucketStrategy = @ptrCast(@alignCast(ctx));
                allocator.destroy(s);
            }

            const vtable = RateLimitStrategy.VTable{
                .tryAcquire = &doTryAcquire,
                .releaseInflight = &doReleaseInflight,
                .applyRetryAfter = &doApplyRetryAfter,
                .activeInflight = &doActiveInflight,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
