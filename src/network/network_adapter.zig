const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/ast.zig");
const abi = @import("../abi/mod.zig");
const policy_engine = @import("policy_engine.zig");
const rate_limiter = @import("rate_limiter.zig");
const proxy_pool = @import("proxy_pool.zig");
const router_redirect = @import("router_redirect.zig");
const dns_cache = @import("dns_cache.zig");
const pcapng_writer = @import("pcapng_writer.zig");

/// Canonical telemetry record emitted onto the built-in `network.captured_events` stream.
/// Matches `components.schemas.network_event` for $O(1)$ router predicates (`count(...) > 0`, `verdict == 'BLOCKED'`).
pub const NetworkEvent = struct {
    event_id: i64,
    step_id: []const u8,
    timestamp: i64,
    protocol: []const u8,
    http_method: []const u8,
    dst_host: []const u8,
    dst_port: i64,
    uri_path: []const u8,
    proxy_used: []const u8,
    status_code: i64,
    latency_ms: i64,
    verdict: []const u8, // "ALLOWED" | "BLOCKED" | "CAPTURED" | "MOCKED" | "RATE_LIMITED"
};

/// Mandatory low-level adapter telemetry counters.
pub const AdapterMetrics = struct {
    active_connections: usize = 0,
    pending_acquires: usize = 0,
    dns_cache_hits: usize = 0,
    dns_cache_misses: usize = 0,
    circuit_breaker_trips: usize = 0,
    backpressure_stall_ms: u64 = 0,
    allocated_buffer_bytes: usize = 0,
    requests_allowed: usize = 0,
    requests_blocked: usize = 0,
    requests_rate_limited: usize = 0,
    packets_captured: usize = 0,
};

pub const TransportResult = struct {
    status_code: u16 = 200,
    body: []const u8 = "",
    latency_ms: u64 = 1,
    retry_after_ms: u64 = 0,
};

/// Pluggable transport handler signature for decoupling L4/L7 adapter logic from physical sockets.
pub const TransportHandlerFn = *const fn (
    userdata: ?*anyopaque,
    allocator: Allocator,
    effective_url: []const u8,
    operation: []const u8,
    proxy_url: ?[]const u8,
    body: []const u8,
) anyerror!TransportResult;

/// Live runtime instance of a Reactive Virtual Network Adapter (`networks:`).
pub const NetworkAdapter = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    spec: ast.NetworkSpec,

    limiter: rate_limiter.RateLimiter,
    proxies: proxy_pool.ProxyPool,
    redirects: router_redirect.RedirectRouter,
    dns: dns_cache.DnsCache,
    pcap: ?pcapng_writer.PcapngWriter = null,
    pcap_interface_id: u32 = 0,

    events: std.ArrayListUnmanaged(NetworkEvent) = .empty,
    next_event_id: i64 = 1,
    clock_ms: u64 = 1000,
    metrics: AdapterMetrics = .{},

    transport_userdata: ?*anyopaque = null,
    transport_fn: ?TransportHandlerFn = null,

    pub fn init(allocator: Allocator, spec: ast.NetworkSpec) !NetworkAdapter {
        var pcap: ?pcapng_writer.PcapngWriter = null;
        var if_id: u32 = 0;
        if (spec.capture.enabled) {
            var writer = try pcapng_writer.PcapngWriter.init(allocator, spec.capture.snaplen);
            errdefer writer.deinit();
            if_id = try writer.registerInterface(spec.id);
            if (spec.capture.include_tls_keys) {
                try writer.writeDecryptionSecretsBlock("CLIENT_RANDOM 0001020304050607 08090a0b0c0d0e0f\n");
            }
            pcap = writer;
        }

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .spec = spec,
            .limiter = rate_limiter.RateLimiter.init(spec.rate_limit, spec.pool, 1000),
            .proxies = try proxy_pool.ProxyPool.init(allocator, spec.proxies),
            .redirects = try router_redirect.RedirectRouter.init(allocator, spec.redirects),
            .dns = dns_cache.DnsCache.init(allocator, spec.dns),
            .pcap = pcap,
            .pcap_interface_id = if_id,
        };
    }

    pub fn deinit(self: *NetworkAdapter) void {
        if (self.pcap) |*w| w.deinit();
        self.dns.deinit();
        self.redirects.deinit(self.allocator);
        self.proxies.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn setTransportHandler(self: *NetworkAdapter, userdata: ?*anyopaque, handler: TransportHandlerFn) void {
        self.transport_userdata = userdata;
        self.transport_fn = handler;
    }

    pub fn advanceClockMs(self: *NetworkAdapter, delta_ms: u64) void {
        self.clock_ms += delta_ms;
    }

    /// Executes a mediated request through the adapter pipeline:
    /// Redirect -> Split Route -> DNS/Anti-SSRF/L7 ACL -> Buffer Quota -> Token Bucket -> Proxy Pool -> Transport & PCAPNG.
    pub fn executeRequest(
        self: *NetworkAdapter,
        step_id: []const u8,
        task_name: []const u8,
        req: abi.NetRequest_ABI,
        out_resp: *abi.NetResponse_ABI,
    ) abi.HostError_ABI {
        const a = self.arena.allocator();
        const raw_url = req.url.asSlice();
        const operation = req.operation.asSlice();

        // 1. Apply transparent URL redirections (`redirects:`) unless driver is strict `none`
        const effective_url = if (self.spec.driver != .none)
            self.redirects.applyRedirects(a, raw_url) catch return .out_of_memory
        else
            raw_url;

        const parsed_uri = policy_engine.ParsedUri.parse(effective_url) orelse return .invalid_argument;

        // 2. Scoped DNS Cache lookup
        const dns_res = self.dns.resolve(parsed_uri.host, self.clock_ms);
        self.metrics.dns_cache_hits = self.dns.hits;
        self.metrics.dns_cache_misses = self.dns.misses;

        // 3. Evaluate Driver, Anti-SSRF, and L4/L7 Combinatorial ACL Policy
        const policy_verdict = policy_engine.evaluateOutboundPolicy(
            self.spec.driver,
            self.spec.policy,
            parsed_uri,
            operation,
            dns_res.ip_address,
        );

        if (policy_verdict != .allowed) {
            self.metrics.requests_blocked += 1;
            self.recordTelemetryAndPcap(
                step_id,
                task_name,
                parsed_uri,
                operation,
                "",
                0,
                0,
                "BLOCKED",
                req.body.asSlice(),
            ) catch return .out_of_memory;
            return .network_policy_denied;
        }

        // 4. Virtual Sinkhole (`driver: sinkhole`) intercepts traffic 100% offline
        if (self.spec.driver == .sinkhole) {
            const verdict = if (self.spec.emulate_responses) "MOCKED" else "CAPTURED";
            const status_code: u16 = if (self.spec.emulate_responses) 200 else 0;
            const body_slice: []const u8 = if (self.spec.emulate_responses) "{\"status\":\"mocked_by_sinkhole\"}" else "";

            self.recordTelemetryAndPcap(
                step_id,
                task_name,
                parsed_uri,
                operation,
                "",
                status_code,
                1,
                verdict,
                if (body_slice.len > 0) body_slice else req.body.asSlice(),
            ) catch return .out_of_memory;

            if (self.spec.emulate_responses) {
                out_resp.* = .{
                    .status_code = status_code,
                    .body = abi.Slice_ABI.fromSlice(body_slice),
                    .effective_url = abi.Slice_ABI.fromSlice(effective_url),
                    .proxy_used = abi.Slice_ABI.fromSlice(""),
                    .latency_ms = 1,
                };
                return .ok;
            }
            return .network_policy_denied;
        }

        // 5. Check Off-Heap Buffer Memory Quota (`backpressure.max_buffer_memory_mb`)
        const max_buf_bytes = self.spec.backpressure.max_buffer_memory_mb * 1024 * 1024;
        if (max_buf_bytes > 0 and (self.metrics.allocated_buffer_bytes + req.body.len > max_buf_bytes)) {
            self.metrics.backpressure_stall_ms += 10;
            return .out_of_memory;
        }

        // 6. Match per-domain split-tunnel route overrides (`routes:`)
        const matched_route = router_redirect.matchSplitRoute(self.spec.routes, parsed_uri.host);
        const strategy_override: ?ast.ProxyStrategy = if (matched_route) |rt| rt.proxy_strategy else null;

        // 7. Token Bucket Rate-Limiting & Pool Envelope Acquisition (with deterministic `defer releaseInflight`)
        const acq = self.limiter.tryAcquire(self.clock_ms, req.body.len);
        if (acq != .allowed) {
            self.metrics.requests_rate_limited += 1;
            self.recordTelemetryAndPcap(
                step_id,
                task_name,
                parsed_uri,
                operation,
                "",
                429,
                0,
                "RATE_LIMITED",
                req.body.asSlice(),
            ) catch return .out_of_memory;
            return if (acq == .pool_exhausted) .network_acquire_timeout else .network_rate_limited;
        }
        defer self.limiter.releaseInflight();
        self.metrics.active_connections = self.limiter.active_inflight;

        // 8. Proxy Pool Selection + Automatic Failover Loop across healthy endpoints
        const max_attempts: usize = if (self.proxies.states.len > 0) self.proxies.states.len else 1;
        var attempt: usize = 0;

        while (attempt < max_attempts) : (attempt += 1) {
            const selected_proxy = self.proxies.select(strategy_override, parsed_uri.host, self.clock_ms);
            const proxy_url: []const u8 = if (selected_proxy) |sp| sp.url else "";

            // Execute transport (custom handler if registered, otherwise synthetic 200 OK in offline mode)
            const tr: TransportResult = if (self.transport_fn) |tfn|
                tfn(self.transport_userdata, a, effective_url, operation, if (proxy_url.len > 0) proxy_url else null, req.body.asSlice()) catch {
                    if (selected_proxy) |sp| {
                        self.proxies.recordFailure(sp.index, 0, self.clock_ms);
                        self.metrics.circuit_breaker_trips = self.proxies.circuit_breaker_trips;
                    }
                    continue;
                }
            else
                TransportResult{
                    .status_code = 200,
                    .body = "",
                    .latency_ms = 5,
                };

            // Check if upstream returned Retry-After or failover status
            if (tr.retry_after_ms > 0) {
                self.limiter.applyRetryAfter(self.clock_ms, tr.retry_after_ms);
            }

            if (selected_proxy) |sp| {
                var is_failover_status = false;
                for (self.spec.proxies.circuit_breaker.failover_on_status) |code| {
                    if (code == tr.status_code) {
                        is_failover_status = true;
                        break;
                    }
                }
                if (is_failover_status) {
                    self.proxies.recordFailure(sp.index, tr.status_code, self.clock_ms);
                    self.metrics.circuit_breaker_trips = self.proxies.circuit_breaker_trips;
                    if (attempt + 1 < max_attempts) continue;
                } else {
                    self.proxies.recordSuccess(sp.index, tr.latency_ms);
                }
            }

            self.metrics.requests_allowed += 1;
            self.recordTelemetryAndPcap(
                step_id,
                task_name,
                parsed_uri,
                operation,
                proxy_url,
                tr.status_code,
                tr.latency_ms,
                "ALLOWED",
                if (tr.body.len > 0) tr.body else req.body.asSlice(),
            ) catch return .out_of_memory;

            out_resp.* = .{
                .status_code = tr.status_code,
                .body = abi.Slice_ABI.fromSlice(tr.body),
                .effective_url = abi.Slice_ABI.fromSlice(effective_url),
                .proxy_used = abi.Slice_ABI.fromSlice(proxy_url),
                .latency_ms = tr.latency_ms,
            };
            return .ok;
        }

        return .network_upstream_error;
    }

    pub fn capturedEventsSlice(self: *const NetworkAdapter) []const NetworkEvent {
        return self.events.items;
    }

    pub fn pcapBytes(self: *const NetworkAdapter) ?[]const u8 {
        if (self.pcap) |*w| return w.bytes();
        return null;
    }

    fn recordTelemetryAndPcap(
        self: *NetworkAdapter,
        step_id: []const u8,
        task_name: []const u8,
        uri: policy_engine.ParsedUri,
        operation: []const u8,
        proxy_used: []const u8,
        status_code: u16,
        latency_ms: u64,
        verdict: []const u8,
        payload_sample: []const u8,
    ) !void {
        const a = self.arena.allocator();
        const ev_id = self.next_event_id;
        self.next_event_id += 1;

        try self.events.append(a, .{
            .event_id = ev_id,
            .step_id = try a.dupe(u8, step_id),
            .timestamp = @intCast(self.clock_ms),
            .protocol = try a.dupe(u8, uri.scheme),
            .http_method = try a.dupe(u8, operation),
            .dst_host = try a.dupe(u8, uri.host),
            .dst_port = @intCast(uri.port),
            .uri_path = try a.dupe(u8, uri.resource),
            .proxy_used = try a.dupe(u8, proxy_used),
            .status_code = @intCast(status_code),
            .latency_ms = @intCast(latency_ms),
            .verdict = verdict,
        });

        if (self.pcap) |*writer| {
            var comment_buf: [256]u8 = undefined;
            const comment = std.fmt.bufPrint(
                &comment_buf,
                "step_id={s} task={s} proxy={s} verdict={s}",
                .{ step_id, task_name, if (proxy_used.len > 0) proxy_used else "direct", verdict },
            ) catch "flowdata_pkt";

            var pkt_buf: [512]u8 = undefined;
            const l7_frame = if (payload_sample.len > 0)
                payload_sample
            else
                (std.fmt.bufPrint(&pkt_buf, "{s} {s} ({s})\r\nHost: {s}\r\n\r\n", .{ operation, uri.resource, uri.scheme, uri.host }) catch "");

            try writer.writeCapturedPacket(
                self.pcap_interface_id,
                self.clock_ms,
                .{ 10, 254, 0, 2 },
                .{ 104, 18, 40, 10 },
                50000 + @as(u16, @truncate(@as(usize, @intCast(ev_id)) % 10000)),
                uri.port,
                l7_frame,
                comment,
            );
            self.metrics.packets_captured = writer.packets_written;
        }
    }
};
