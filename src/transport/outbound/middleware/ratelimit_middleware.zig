const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const NetMiddleware = contracts.NetMiddleware;
const NextHandler = contracts.NextHandler;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const RateLimitStrategy = contracts.RateLimitStrategy;
const BackpressureConfig = contracts.BackpressureConfig;

/// Composable Rate-Limiting & Backpressure Envelope interceptor.
/// Delegates token acquisition to an injected `RateLimitStrategy` VTable and enforces `max_buffer_memory_mb`.
pub const RateLimitMiddleware = struct {
    comptime {
        NetMiddleware.assertImplements(@This());
    }

    limiter: RateLimitStrategy,
    backpressure: BackpressureConfig,

    pub fn createHeap(
        allocator: Allocator,
        limiter: RateLimitStrategy,
        backpressure: BackpressureConfig,
    ) !NetMiddleware {
        const self = try allocator.create(RateLimitMiddleware);
        self.* = .{
            .limiter = limiter,
            .backpressure = backpressure,
        };
        return self.netMiddleware();
    }

    pub fn intercept(self: *RateLimitMiddleware, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
        const max_buf_bytes = self.backpressure.max_buffer_memory_mb * 1024 * 1024;
        if (max_buf_bytes > 0 and (exchange.metrics.allocated_buffer_bytes + exchange.req_body.len > max_buf_bytes)) {
            exchange.metrics.backpressure_stall_ms += 10;
            return error.OutOfMemory;
        }

        var current_now = exchange.now_ms;
        var decision = self.limiter.tryAcquire(current_now, exchange.req_body.len);
        if (decision == .rate_limited_rps or decision == .rate_limited_bandwidth) {
            const max_pacing_wait_ms: u64 = 30_000;
            var waited_ms: u64 = 0;
            while (decision == .rate_limited_rps or decision == .rate_limited_bandwidth) {
                const hint = self.limiter.waitHintMs(current_now, exchange.req_body.len);
                const slice_ms: u64 = @min(@max(hint, 5), 500);
                if (waited_ms + slice_ms > max_pacing_wait_ms) break;

                var ts: std.c.timespec = .{
                    .sec = @intCast(slice_ms / 1000),
                    .nsec = @intCast((slice_ms % 1000) * 1_000_000),
                };
                _ = std.c.nanosleep(&ts, null);
                waited_ms += slice_ms;
                current_now += slice_ms;
                decision = self.limiter.tryAcquire(current_now, exchange.req_body.len);
            }
        }
        if (decision != .allowed) {
            exchange.metrics.requests_rate_limited += 1;
            return if (decision == .pool_exhausted) error.NetworkAcquireTimeout else error.NetworkRateLimited;
        }
        defer self.limiter.releaseInflight();

        exchange.metrics.active_connections = self.limiter.activeInflight();

        const res = try next_handler.next(exchange);
        if (res.retry_after_ms > 0) {
            self.limiter.applyRetryAfter(current_now, res.retry_after_ms);
        }
        return res;
    }

    pub fn netMiddleware(self: *RateLimitMiddleware) NetMiddleware {
        const Trampoline = struct {
            fn doIntercept(ctx: *anyopaque, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
                const s: *RateLimitMiddleware = @ptrCast(@alignCast(ctx));
                return try s.intercept(exchange, next_handler);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *RateLimitMiddleware = @ptrCast(@alignCast(ctx));
                s.limiter.deinit(allocator);
                allocator.destroy(s);
            }

            const vtable = NetMiddleware.VTable{
                .intercept = &doIntercept,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
