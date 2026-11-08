const std = @import("std");
const Allocator = std.mem.Allocator;

pub const AcquireDecision = enum {
    allowed,
    rate_limited_rps,
    rate_limited_bandwidth,
    rate_limited_retry_after,
    pool_exhausted,
};

/// Polymorphic VTable interface for Traffic Shaping & Rate-Limiting strategies (Token Bucket, Leaky Bucket, Sliding Window, etc.).
pub const RateLimitStrategy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        tryAcquire: *const fn (ctx: *anyopaque, now_ms: u64, payload_bytes: usize) AcquireDecision,
        releaseInflight: *const fn (ctx: *anyopaque) void,
        applyRetryAfter: *const fn (ctx: *anyopaque, now_ms: u64, retry_after_ms: u64) void,
        activeInflight: *const fn (ctx: *const anyopaque) usize,
        deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub fn tryAcquire(self: RateLimitStrategy, now_ms: u64, payload_bytes: usize) AcquireDecision {
        return self.vtable.tryAcquire(self.ptr, now_ms, payload_bytes);
    }

    pub fn releaseInflight(self: RateLimitStrategy) void {
        self.vtable.releaseInflight(self.ptr);
    }

    pub fn applyRetryAfter(self: RateLimitStrategy, now_ms: u64, retry_after_ms: u64) void {
        self.vtable.applyRetryAfter(self.ptr, now_ms, retry_after_ms);
    }

    pub fn activeInflight(self: RateLimitStrategy) usize {
        return self.vtable.activeInflight(self.ptr);
    }

    pub fn deinit(self: RateLimitStrategy, allocator: Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "rateLimitStrategy")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn rateLimitStrategy(*" ++ @typeName(T) ++ ") RateLimitStrategy'");
            }
        }
    }
};
