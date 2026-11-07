const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/ast.zig");

pub const BreakerState = enum {
    closed,
    open,
    half_open,
};

pub const ProxyRuntimeState = struct {
    url: []const u8,
    weight: i32,
    current_weight: i32 = 0,
    state: BreakerState = .closed,
    consecutive_failures: u32 = 0,
    cooldown_until_ms: u64 = 0,
    half_open_calls: u32 = 0,
    ewma_latency_ms: f64 = 50.0,
    active_inflight: usize = 0,

    pub fn isAvailable(self: *ProxyRuntimeState, cb_spec: ast.CircuitBreakerSpec, now_ms: u64) bool {
        switch (self.state) {
            .closed => return true,
            .open => {
                if (now_ms >= self.cooldown_until_ms) {
                    self.state = .half_open;
                    self.half_open_calls = 0;
                    return true;
                }
                return false;
            },
            .half_open => {
                return self.half_open_calls < cb_spec.half_open_max_calls;
            },
        }
    }
};

pub const SelectedProxy = struct {
    index: usize,
    url: []const u8,
};

/// Multi-Strategy Proxy Selector with Integrated Circuit Breaker.
/// Supports `round_robin`, Smooth `weighted`, `failover`, `least_latency` (EWMA), `sticky_host`, and `random`.
pub const ProxyPool = struct {
    spec: ast.ProxyPoolSpec,
    states: []ProxyRuntimeState,
    rr_cursor: usize = 0,
    prng_state: u64 = 0x853c49e6748fea9b,
    circuit_breaker_trips: usize = 0,

    pub fn init(allocator: Allocator, spec: ast.ProxyPoolSpec) !ProxyPool {
        const states = try allocator.alloc(ProxyRuntimeState, spec.endpoints.len);
        for (spec.endpoints, 0..) |ep, i| {
            const w: i32 = if (ep.weight > 0) @intCast(ep.weight) else 1;
            states[i] = .{
                .url = ep.url,
                .weight = w,
            };
        }
        return .{
            .spec = spec,
            .states = states,
        };
    }

    pub fn deinit(self: *ProxyPool, allocator: Allocator) void {
        allocator.free(self.states);
    }

    pub fn select(
        self: *ProxyPool,
        strategy_override: ?ast.ProxyStrategy,
        dst_host: []const u8,
        now_ms: u64,
    ) ?SelectedProxy {
        if (self.states.len == 0) return null;
        const strategy = strategy_override orelse self.spec.strategy;

        const chosen_idx: ?usize = switch (strategy) {
            .round_robin => self.selectRoundRobin(now_ms),
            .weighted => self.selectSmoothWeighted(now_ms),
            .failover => self.selectFailover(now_ms),
            .least_latency => self.selectLeastLatency(now_ms),
            .sticky_host => self.selectStickyHost(dst_host, now_ms),
            .random => self.selectRandom(now_ms),
        };

        if (chosen_idx) |idx| {
            if (self.states[idx].state == .half_open) {
                self.states[idx].half_open_calls += 1;
            }
            self.states[idx].active_inflight += 1;
            return .{
                .index = idx,
                .url = self.states[idx].url,
            };
        }
        return null;
    }

    pub fn recordSuccess(self: *ProxyPool, index: usize, latency_ms: u64) void {
        if (index >= self.states.len) return;
        var st = &self.states[index];
        if (st.active_inflight > 0) st.active_inflight -= 1;
        st.consecutive_failures = 0;
        st.state = .closed;
        st.half_open_calls = 0;

        const sample: f64 = @floatFromInt(latency_ms);
        st.ewma_latency_ms = (st.ewma_latency_ms * 0.7) + (sample * 0.3);
    }

    pub fn recordFailure(self: *ProxyPool, index: usize, status_code: u16, now_ms: u64) void {
        if (index >= self.states.len) return;
        var st = &self.states[index];
        if (st.active_inflight > 0) st.active_inflight -= 1;

        var should_count = (status_code == 0); // transport error
        if (!should_count) {
            for (self.spec.circuit_breaker.failover_on_status) |code| {
                if (code == status_code) {
                    should_count = true;
                    break;
                }
            }
        }
        if (!should_count) return;

        st.consecutive_failures += 1;
        if (st.state == .half_open or st.consecutive_failures >= self.spec.circuit_breaker.failure_threshold) {
            st.state = .open;
            st.cooldown_until_ms = now_ms + self.spec.circuit_breaker.cooldown_ms;
            self.circuit_breaker_trips += 1;
        }
    }

    fn selectRoundRobin(self: *ProxyPool, now_ms: u64) ?usize {
        const n = self.states.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const idx = (self.rr_cursor + i) % n;
            if (self.states[idx].isAvailable(self.spec.circuit_breaker, now_ms)) {
                self.rr_cursor = (idx + 1) % n;
                return idx;
            }
        }
        return null;
    }

    fn selectSmoothWeighted(self: *ProxyPool, now_ms: u64) ?usize {
        var total_weight: i32 = 0;
        var best_idx: ?usize = null;
        var best_weight: i32 = std.math.minInt(i32);

        for (self.states, 0..) |*st, idx| {
            if (!st.isAvailable(self.spec.circuit_breaker, now_ms)) continue;
            st.current_weight += st.weight;
            total_weight += st.weight;
            if (best_idx == null or st.current_weight > best_weight) {
                best_weight = st.current_weight;
                best_idx = idx;
            }
        }

        if (best_idx) |idx| {
            self.states[idx].current_weight -= total_weight;
            return idx;
        }
        return null;
    }

    fn selectFailover(self: *ProxyPool, now_ms: u64) ?usize {
        for (self.states, 0..) |*st, idx| {
            if (st.isAvailable(self.spec.circuit_breaker, now_ms)) {
                return idx;
            }
        }
        return null;
    }

    fn selectLeastLatency(self: *ProxyPool, now_ms: u64) ?usize {
        var best_idx: ?usize = null;
        var best_score: f64 = std.math.floatMax(f64);

        for (self.states, 0..) |*st, idx| {
            if (!st.isAvailable(self.spec.circuit_breaker, now_ms)) continue;
            const inflight_penalty: f64 = @as(f64, @floatFromInt(st.active_inflight)) * 25.0;
            const score = st.ewma_latency_ms + inflight_penalty;
            if (best_idx == null or score < best_score) {
                best_score = score;
                best_idx = idx;
            }
        }
        return best_idx;
    }

    fn selectStickyHost(self: *ProxyPool, dst_host: []const u8, now_ms: u64) ?usize {
        var available_count: usize = 0;
        for (self.states) |*st| {
            if (st.isAvailable(self.spec.circuit_breaker, now_ms)) {
                available_count += 1;
            }
        }
        if (available_count == 0) return null;

        const hash = std.hash.Fnv1a_64.hash(dst_host);
        const target_slot = @as(usize, @intCast(hash % available_count));

        var current_slot: usize = 0;
        for (self.states, 0..) |*st, idx| {
            if (st.isAvailable(self.spec.circuit_breaker, now_ms)) {
                if (current_slot == target_slot) return idx;
                current_slot += 1;
            }
        }
        return null;
    }

    fn selectRandom(self: *ProxyPool, now_ms: u64) ?usize {
        var available_count: usize = 0;
        for (self.states) |*st| {
            if (st.isAvailable(self.spec.circuit_breaker, now_ms)) {
                available_count += 1;
            }
        }
        if (available_count == 0) return null;

        // Xorshift64*
        var x = self.prng_state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.prng_state = x;
        const rnd = x *% 0x2545F4914F6CDD1D;
        const target_slot = @as(usize, @intCast(rnd % available_count));

        var current_slot: usize = 0;
        for (self.states, 0..) |*st, idx| {
            if (st.isAvailable(self.spec.circuit_breaker, now_ms)) {
                if (current_slot == target_slot) return idx;
                current_slot += 1;
            }
        }
        return null;
    }
};

test "proxy_pool: round_robin, smooth weighted, least_latency, sticky_host, and circuit breaker failover" {
    const testing = std.testing;
    const endpoints = [_]ast.ProxyEndpointSpec{
        .{ .url = "http://proxy-1:8080", .weight = 2 },
        .{ .url = "http://proxy-2:8080", .weight = 1 },
        .{ .url = "socks5://proxy-3:1080", .weight = 1 },
    };

    var pool = try ProxyPool.init(testing.allocator, .{
        .strategy = .round_robin,
        .circuit_breaker = .{
            .failure_threshold = 2,
            .cooldown_ms = 5000,
        },
        .endpoints = &endpoints,
    });
    defer pool.deinit(testing.allocator);

    // 1. Round Robin
    const p0 = pool.select(null, "api.mangadex.org", 1000).?;
    const p1 = pool.select(null, "api.mangadex.org", 1000).?;
    const p2 = pool.select(null, "api.mangadex.org", 1000).?;
    try testing.expectEqualStrings("http://proxy-1:8080", p0.url);
    try testing.expectEqualStrings("http://proxy-2:8080", p1.url);
    try testing.expectEqualStrings("socks5://proxy-3:1080", p2.url);
    pool.recordSuccess(p0.index, 40);
    pool.recordSuccess(p1.index, 120);
    pool.recordSuccess(p2.index, 15);

    // 2. Least Latency picks proxy-3 (ewma updated with 15ms)
    const fast = pool.select(.least_latency, "s1.mangadex.network", 1000).?;
    try testing.expectEqualStrings("socks5://proxy-3:1080", fast.url);
    pool.recordSuccess(fast.index, 15);

    // 3. Sticky Host returns identical proxy for identical hostname
    const sticky_a1 = pool.select(.sticky_host, "node-42.mangadex.network", 1000).?;
    pool.recordSuccess(sticky_a1.index, 20);
    const sticky_a2 = pool.select(.sticky_host, "node-42.mangadex.network", 1000).?;
    pool.recordSuccess(sticky_a2.index, 20);
    try testing.expectEqualStrings(sticky_a1.url, sticky_a2.url);

    // 4. Failover + Circuit Breaker: trip proxy-1 with two 429 failures
    const f1 = pool.select(.failover, "api.mangadex.org", 2000).?;
    try testing.expectEqualStrings("http://proxy-1:8080", f1.url);
    pool.recordFailure(f1.index, 429, 2000);
    pool.recordFailure(f1.index, 429, 2000);
    try testing.expectEqual(@as(usize, 1), pool.circuit_breaker_trips);

    // Next failover call automatically skips OPEN proxy-1 and selects proxy-2
    const f2 = pool.select(.failover, "api.mangadex.org", 2500).?;
    try testing.expectEqualStrings("http://proxy-2:8080", f2.url);
    pool.recordSuccess(f2.index, 30);

    // After 5000ms cooldown (t=7500), proxy-1 transitions to HALF_OPEN and recovers on success
    const f3 = pool.select(.failover, "api.mangadex.org", 7500).?;
    try testing.expectEqualStrings("http://proxy-1:8080", f3.url);
    pool.recordSuccess(f3.index, 25);
    try testing.expectEqual(BreakerState.closed, pool.states[0].state);
}
