const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const strategies = @import("../strategies/mod.zig");

const NetMiddleware = contracts.NetMiddleware;
const NextHandler = contracts.NextHandler;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const ProxyPoolConfig = contracts.ProxyPoolConfig;
const ProxyEndpointState = contracts.ProxyEndpointState;
const ProxySelectorStrategy = contracts.ProxySelectorStrategy;
const RouteRuleConfig = contracts.RouteRuleConfig;
const ProxyStrategyRegistry = strategies.ProxyStrategyRegistry;

/// Composable Split-Tunnel Route & Multi-Strategy Proxy Failover interceptor.
/// Uses polymorphic `ProxySelectorStrategy` VTables (zero `switch` statements) and manages Circuit Breaker state.
pub const ProxyRouterMiddleware = struct {
    comptime {
        NetMiddleware.assertImplements(@This());
    }

    allocator: Allocator,
    spec: ProxyPoolConfig,
    routes: []const RouteRuleConfig,
    endpoints: []ProxyEndpointState,
    default_strategy: ProxySelectorStrategy,
    strategy_overrides: std.StringHashMapUnmanaged(ProxySelectorStrategy) = .empty,
    circuit_breaker_trips: usize = 0,

    pub fn createHeap(
        allocator: Allocator,
        spec: ProxyPoolConfig,
        routes: []const RouteRuleConfig,
        strategy_registry: *const ProxyStrategyRegistry,
    ) !NetMiddleware {
        const self = try allocator.create(ProxyRouterMiddleware);
        errdefer allocator.destroy(self);

        const endpoints = try allocator.alloc(ProxyEndpointState, spec.endpoints.len);
        errdefer allocator.free(endpoints);
        for (spec.endpoints, 0..) |ep, i| {
            endpoints[i] = .{ .spec = ep };
        }

        const default_strat = try strategy_registry.instantiate(spec.effectiveStrategyName());
        errdefer default_strat.deinit(allocator);

        var overrides: std.StringHashMapUnmanaged(ProxySelectorStrategy) = .empty;
        errdefer {
            var it = overrides.iterator();
            while (it.next()) |kv| {
                allocator.free(kv.key_ptr.*);
                kv.value_ptr.deinit(allocator);
            }
            overrides.deinit(allocator);
        }

        for (routes) |rt| {
            if (rt.effectiveProxyStrategyName()) |sname| {
                if (!overrides.contains(sname)) {
                    const strat = try strategy_registry.instantiate(sname);
                    errdefer strat.deinit(allocator);
                    const owned_name = try allocator.dupe(u8, sname);
                    try overrides.put(allocator, owned_name, strat);
                }
            }
        }

        self.* = .{
            .allocator = allocator,
            .spec = spec,
            .routes = routes,
            .endpoints = endpoints,
            .default_strategy = default_strat,
            .strategy_overrides = overrides,
        };
        return self.netMiddleware();
    }

    pub fn intercept(self: *ProxyRouterMiddleware, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
        if (self.endpoints.len == 0) {
            const res = try next_handler.next(exchange);
            exchange.metrics.requests_allowed += 1;
            return res;
        }

        // Resolve per-host split-tunnel strategy override if configured
        var active_strategy = self.default_strategy;
        for (self.routes) |rt| {
            if (strategies.policy.matchGlob(rt.match_host, exchange.uri.host)) {
                if (rt.effectiveProxyStrategyName()) |sname| {
                    if (self.strategy_overrides.get(sname)) |ov_strat| {
                        active_strategy = ov_strat;
                    }
                }
                break;
            }
        }

        const max_attempts = self.endpoints.len;
        var attempt: usize = 0;

        while (attempt < max_attempts) : (attempt += 1) {
            const chosen_idx = active_strategy.select(
                self.endpoints,
                self.spec.circuit_breaker,
                exchange.uri.host,
                exchange.now_ms,
            ) orelse return error.NetworkUpstreamError;

            self.endpoints[chosen_idx].active_inflight += 1;
            defer if (self.endpoints[chosen_idx].active_inflight > 0) {
                self.endpoints[chosen_idx].active_inflight -= 1;
            };

            exchange.selected_proxy_url = self.endpoints[chosen_idx].spec.url;

            const res = next_handler.next(exchange) catch |err| {
                if (err == error.NetworkUpstreamError) {
                    self.recordFailure(chosen_idx, 0, exchange.now_ms);
                    exchange.metrics.circuit_breaker_trips = self.circuit_breaker_trips;
                    continue;
                }
                return err;
            };

            if (self.isFailoverStatus(res.status_code)) {
                self.recordFailure(chosen_idx, res.status_code, exchange.now_ms);
                exchange.metrics.circuit_breaker_trips = self.circuit_breaker_trips;
                if (attempt + 1 < max_attempts) continue;
            } else {
                self.recordSuccess(chosen_idx, res.latency_ms);
            }

            exchange.metrics.requests_allowed += 1;
            var out = res;
            out.proxy_used = exchange.selected_proxy_url;
            return out;
        }

        return error.NetworkUpstreamError;
    }

    fn isFailoverStatus(self: *const ProxyRouterMiddleware, status_code: u16) bool {
        for (self.spec.circuit_breaker.failover_on_status) |code| {
            if (code == status_code) return true;
        }
        return false;
    }

    fn recordSuccess(self: *ProxyRouterMiddleware, index: usize, latency_ms: u64) void {
        var st = &self.endpoints[index];
        st.consecutive_failures = 0;
        st.circuit = .closed;
        const alpha: f64 = 0.3;
        const sample: f64 = @floatFromInt(@max(latency_ms, 1));
        st.ewma_latency_ms = (alpha * sample) + ((1.0 - alpha) * st.ewma_latency_ms);
    }

    fn recordFailure(self: *ProxyRouterMiddleware, index: usize, _: u16, now_ms: u64) void {
        var st = &self.endpoints[index];
        st.consecutive_failures += 1;
        st.ewma_latency_ms *= 2.0;

        if (st.circuit == .half_open or st.consecutive_failures >= self.spec.circuit_breaker.failure_threshold) {
            if (st.circuit != .open) {
                self.circuit_breaker_trips += 1;
            }
            st.circuit = .open;
            st.opened_at_ms = now_ms;
        }
    }

    pub fn netMiddleware(self: *ProxyRouterMiddleware) NetMiddleware {
        const Trampoline = struct {
            fn doIntercept(ctx: *anyopaque, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
                const s: *ProxyRouterMiddleware = @ptrCast(@alignCast(ctx));
                return try s.intercept(exchange, next_handler);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *ProxyRouterMiddleware = @ptrCast(@alignCast(ctx));
                var it = s.strategy_overrides.iterator();
                while (it.next()) |kv| {
                    allocator.free(kv.key_ptr.*);
                    kv.value_ptr.deinit(allocator);
                }
                s.strategy_overrides.deinit(allocator);
                s.default_strategy.deinit(allocator);
                allocator.free(s.endpoints);
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
