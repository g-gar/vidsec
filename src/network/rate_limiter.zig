const std = @import("std");
const ast = @import("../ast/ast.zig");

pub const AcquireVerdict = enum {
    allowed,
    rate_limited,
    bandwidth_exceeded,
    pool_exhausted,
    retry_after_cooldown,
};

/// Dual Token Bucket + Resource Envelope Manager.
/// Governs both discrete request rate (`requests_per_second`), continuous byte-stream bandwidth (`max_bandwidth_mbps`),
/// concurrent connection/inflight envelopes (`max_inflight`, `max_connections`), and upstream `Retry-After` pauses.
pub const RateLimiter = struct {
    spec: ast.RateLimitSpec,
    pool_spec: ast.PoolSpec,

    req_tokens: f64,
    req_capacity: f64,

    byte_tokens: f64,
    byte_capacity: f64,
    bytes_per_sec: f64,

    last_refill_ms: u64 = 0,
    retry_after_until_ms: u64 = 0,
    active_inflight: usize = 0,
    pending_acquires: usize = 0,

    pub fn init(spec: ast.RateLimitSpec, pool_spec: ast.PoolSpec, now_ms: u64) RateLimiter {
        const cap: f64 = if (spec.burst > 0)
            @floatFromInt(spec.burst)
        else if (spec.requests_per_second > 0.0)
            spec.requests_per_second
        else
            0.0;

        const bps: f64 = if (spec.max_bandwidth_mbps > 0.0)
            (spec.max_bandwidth_mbps * 1_000_000.0) / 8.0
        else
            0.0;

        return .{
            .spec = spec,
            .pool_spec = pool_spec,
            .req_tokens = cap,
            .req_capacity = cap,
            .byte_tokens = bps,
            .byte_capacity = bps,
            .bytes_per_sec = bps,
            .last_refill_ms = now_ms,
        };
    }

    pub fn refill(self: *RateLimiter, now_ms: u64) void {
        if (now_ms <= self.last_refill_ms) return;
        const elapsed_sec: f64 = @as(f64, @floatFromInt(now_ms - self.last_refill_ms)) / 1000.0;
        self.last_refill_ms = now_ms;

        if (self.spec.requests_per_second > 0.0) {
            self.req_tokens = @min(self.req_capacity, self.req_tokens + elapsed_sec * self.spec.requests_per_second);
        }
        if (self.bytes_per_sec > 0.0) {
            self.byte_tokens = @min(self.byte_capacity, self.byte_tokens + elapsed_sec * self.bytes_per_sec);
        }
    }

    /// Attempts to acquire a request slot and optional byte budget at `now_ms`.
    pub fn tryAcquire(self: *RateLimiter, now_ms: u64, byte_cost: usize) AcquireVerdict {
        if (self.spec.respect_retry_after and now_ms < self.retry_after_until_ms) {
            return .retry_after_cooldown;
        }

        // Check pool & inflight envelopes
        const max_active = if (self.spec.max_inflight > 0)
            @min(self.spec.max_inflight, self.pool_spec.max_connections)
        else
            self.pool_spec.max_connections;

        if (max_active > 0 and self.active_inflight >= max_active) {
            return .pool_exhausted;
        }

        self.refill(now_ms);

        // Check discrete request token bucket
        if (self.spec.requests_per_second > 0.0) {
            if (self.req_tokens < 1.0) {
                return .rate_limited;
            }
        }

        // Check continuous bandwidth byte bucket
        const cost_f: f64 = @floatFromInt(byte_cost);
        if (self.bytes_per_sec > 0.0 and byte_cost > 0) {
            if (self.byte_tokens < cost_f) {
                return .bandwidth_exceeded;
            }
        }

        if (self.spec.requests_per_second > 0.0) {
            self.req_tokens -= 1.0;
        }
        if (self.bytes_per_sec > 0.0 and byte_cost > 0) {
            self.byte_tokens -= cost_f;
        }
        self.active_inflight += 1;
        return .allowed;
    }

    pub fn releaseInflight(self: *RateLimiter) void {
        if (self.active_inflight > 0) {
            self.active_inflight -= 1;
        }
    }

    /// Applies an upstream `Retry-After` cooldown window when `429` / `503` is received.
    pub fn applyRetryAfter(self: *RateLimiter, now_ms: u64, cooldown_ms: u64) void {
        if (self.spec.respect_retry_after) {
            self.retry_after_until_ms = @max(self.retry_after_until_ms, now_ms + cooldown_ms);
            self.req_tokens = 0.0;
        }
    }
};

test "rate_limiter: Token Bucket burst, refill, inflight cap, and Retry-After cooldown" {
    const testing = std.testing;

    var limiter = RateLimiter.init(.{
        .requests_per_second = 5.0,
        .burst = 2,
        .max_inflight = 2,
        .respect_retry_after = true,
    }, .{
        .max_connections = 10,
    }, 1000);

    // Burst of 2 requests at t=1000ms succeeds
    try testing.expectEqual(AcquireVerdict.allowed, limiter.tryAcquire(1000, 0));
    try testing.expectEqual(AcquireVerdict.allowed, limiter.tryAcquire(1000, 0));

    // 3rd simultaneous request hits max_inflight = 2
    try testing.expectEqual(AcquireVerdict.pool_exhausted, limiter.tryAcquire(1000, 0));

    // Release 1 inflight; now hits rate_limited because bucket is empty at t=1000ms
    limiter.releaseInflight();
    limiter.releaseInflight();
    try testing.expectEqual(AcquireVerdict.rate_limited, limiter.tryAcquire(1000, 0));

    // Advance 200ms (at 5 req/s, 200ms refills 1.0 token) -> allowed!
    try testing.expectEqual(AcquireVerdict.allowed, limiter.tryAcquire(1200, 0));
    limiter.releaseInflight();

    // Upstream returns 429 with Retry-After: 2s (2000ms)
    limiter.applyRetryAfter(1200, 2000);
    try testing.expectEqual(AcquireVerdict.retry_after_cooldown, limiter.tryAcquire(2500, 0));
    try testing.expectEqual(AcquireVerdict.allowed, limiter.tryAcquire(3200, 0));
}
