const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const strategies = @import("../strategies/mod.zig");
const middleware = @import("../middleware/mod.zig");
const sinks = @import("../sinks/mod.zig");
const transports = @import("../transports/mod.zig");

const NetworkAdapter = contracts.NetworkAdapter;
const AdapterConfig = contracts.AdapterConfig;
const MiddlewareChain = contracts.MiddlewareChain;
const TransportRegistry = contracts.TransportRegistry;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const NetStreamId = contracts.NetStreamId;
const CapturedExchangeRecord = contracts.CapturedExchangeRecord;
const AdapterMetrics = contracts.AdapterMetrics;
const PacketSink = contracts.PacketSink;
const Uri = contracts.Uri;
const CustomTransportFn = contracts.CustomTransportFn;

const ProxyStrategyRegistry = strategies.ProxyStrategyRegistry;
const DualTokenBucketStrategy = strategies.DualTokenBucketStrategy;
const ScopedMemoryDnsResolver = strategies.ScopedMemoryDnsResolver;

const RedirectMiddleware = middleware.RedirectMiddleware;
const CaptureMiddleware = middleware.CaptureMiddleware;
const DnsMiddleware = middleware.DnsMiddleware;
const PolicyGuardMiddleware = middleware.PolicyGuardMiddleware;
const RateLimitMiddleware = middleware.RateLimitMiddleware;
const ProxyRouterMiddleware = middleware.ProxyRouterMiddleware;

const MemoryEventSink = sinks.MemoryEventSink;
const PcapngSink = sinks.PcapngSink;
const StreamSessionTable = transports.StreamSessionTable;

/// Reactive Outbound Egress Network Adapter (`driver: egress`).
/// Dynamically snaps together composable Lego `NetMiddleware` stages:
/// `[RedirectMiddleware -> CaptureMiddleware -> DnsMiddleware -> PolicyGuardMiddleware -> RateLimitMiddleware -> ProxyRouterMiddleware]`
/// terminating at a scheme-dispatched `TransportRegistry`.
pub const EgressAdapter = struct {
    comptime {
        NetworkAdapter.assertImplements(@This());
    }

    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    config: AdapterConfig,
    chain: MiddlewareChain,
    transport_reg: TransportRegistry,
    streams: StreamSessionTable,
    event_sink: MemoryEventSink,
    pcap_sink: ?PcapngSink = null,
    adapter_metrics: AdapterMetrics = .{},
    clock_ms: u64 = 1000,

    pub fn createHeap(
        allocator: Allocator,
        config: AdapterConfig,
        strategy_registry: *const ProxyStrategyRegistry,
    ) anyerror!NetworkAdapter {
        const self = try allocator.create(EgressAdapter);
        errdefer allocator.destroy(self);

        var transport_reg = TransportRegistry.init(allocator);
        errdefer transport_reg.deinit();
        try transports.registerDefaultTransports(&transport_reg);

        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .config = config,
            .chain = MiddlewareChain.init(allocator),
            .transport_reg = transport_reg,
            .streams = StreamSessionTable.init(allocator),
            .event_sink = MemoryEventSink.init(allocator),
            .pcap_sink = if (config.capture.enabled)
                try PcapngSink.init(allocator, config.id, config.capture.snaplen, config.capture.include_tls_keys)
            else
                null,
        };
        errdefer self.deinitInternal();

        // 1. URL Mirror Redirections (`redirects:`)
        if (config.redirects.len > 0) {
            try self.chain.use(try RedirectMiddleware.createHeap(allocator, config.redirects));
        }

        // 2. Telemetry & PCAPNG Packet Capture (`capture:` + `network.captured_events`)
        var active_sinks: [2]PacketSink = undefined;
        var sink_count: usize = 1;
        active_sinks[0] = self.event_sink.packetSink();
        if (self.pcap_sink) |*ps| {
            active_sinks[1] = ps.packetSink();
            sink_count = 2;
        }
        try self.chain.use(try CaptureMiddleware.createHeap(allocator, active_sinks[0..sink_count]));

        // 3. Scoped DNS Resolver (`dns:`)
        const dns_resolver = try ScopedMemoryDnsResolver.createHeap(allocator, config.dns);
        try self.chain.use(try DnsMiddleware.createHeap(allocator, dns_resolver));

        // 4. L4/L7 Combinatorial ACL, TLS & Pre-Connect Anti-SSRF Guard (`policy:` + `tls:`)
        const pol_rule = try strategies.CompositePolicy.createFromSpec(allocator, config);
        try self.chain.use(try PolicyGuardMiddleware.createHeap(allocator, pol_rule));

        // 5. Dual Token Bucket Rate-Limiter & Backpressure Quota (`rate_limit:` + `pool:` + `backpressure:`)
        const limiter = try DualTokenBucketStrategy.createHeap(allocator, config.rate_limit, config.pool, 1000);
        try self.chain.use(try RateLimitMiddleware.createHeap(allocator, limiter, config.backpressure));

        // 6. Split-Tunnel Router & Multi-Strategy Proxy Failover Pool (`routes:` + `proxies:`)
        try self.chain.use(try ProxyRouterMiddleware.createHeap(allocator, config.proxies, config.routes, strategy_registry));

        return self.networkAdapter();
    }

    pub fn deinitInternal(self: *EgressAdapter) void {
        self.streams.deinit();
        self.chain.deinit();
        self.transport_reg.deinit();
        if (self.pcap_sink) |*ps| ps.deinitInternal();
        self.event_sink.deinitInternal();
        self.arena.deinit();
    }

    pub fn execute(
        self: *EgressAdapter,
        raw_url: []const u8,
        operation: []const u8,
        body: []const u8,
        trace_tag: []const u8,
    ) NetError!NetResult {
        const uri = Uri.parse(raw_url) orelse return error.InvalidUri;
        var ex = NetExchange{
            .allocator = self.arena.allocator(),
            .adapter_id = self.config.id,
            .trace_tag = trace_tag,
            .now_ms = self.clock_ms,
            .original_url = raw_url,
            .effective_url = raw_url,
            .uri = uri,
            .operation = operation,
            .req_body = body,
            .connect_timeout_ms = self.config.timeouts.connect_ms,
            .read_timeout_ms = self.config.timeouts.read_idle_ms,
            .so_rcvbuf_bytes = self.config.backpressure.so_rcvbuf_bytes,
            .metrics = &self.adapter_metrics,
        };

        return try self.chain.execute(&ex, self.transport_reg.dispatcher());
    }

    pub fn connectStream(
        self: *EgressAdapter,
        raw_url: []const u8,
        operation: []const u8,
        trace_tag: []const u8,
    ) NetError!NetStreamId {
        const res = try self.execute(raw_url, operation, "", trace_tag);
        const uri = Uri.parse(res.effective_url) orelse Uri.parse(raw_url) orelse return error.InvalidUri;
        const greeting = if (res.wire_response.len > 0) res.wire_response else res.body;
        const sid = try self.streams.openSession(uri.scheme, res.effective_url, res.proxy_used, greeting);
        self.adapter_metrics.active_connections = self.streams.sessions.count();
        return sid;
    }

    pub fn networkAdapter(self: *EgressAdapter) NetworkAdapter {
        const Trampoline = struct {
            fn doExecute(
                ctx: *anyopaque,
                raw_url: []const u8,
                operation: []const u8,
                body: []const u8,
                trace_tag: []const u8,
            ) NetError!NetResult {
                const s: *EgressAdapter = @ptrCast(@alignCast(ctx));
                return try s.execute(raw_url, operation, body, trace_tag);
            }

            fn doConnectStream(
                ctx: *anyopaque,
                raw_url: []const u8,
                operation: []const u8,
                trace_tag: []const u8,
            ) NetError!NetStreamId {
                const s: *EgressAdapter = @ptrCast(@alignCast(ctx));
                return try s.connectStream(raw_url, operation, trace_tag);
            }

            fn doStreamSend(ctx: *anyopaque, stream_id: NetStreamId, payload: []const u8) NetError!usize {
                const s: *EgressAdapter = @ptrCast(@alignCast(ctx));
                const n = try s.streams.send(stream_id, payload);
                if (s.pcap_sink) |*ps| {
                    var comment_buf: [128]u8 = undefined;
                    const comment = std.fmt.bufPrint(&comment_buf, "stream_id={d} dir=tx", .{stream_id}) catch "stream_tx";
                    ps.writeCapturedPacket(ps.interface_id, s.clock_ms, .{ 10, 254, 0, 2 }, .{ 104, 18, 40, 10 }, 55000, 443, payload, comment) catch {};
                    s.adapter_metrics.packets_captured = ps.packets_written;
                }
                return n;
            }

            fn doStreamRecv(ctx: *anyopaque, stream_id: NetStreamId, dest: []u8) NetError!usize {
                const s: *EgressAdapter = @ptrCast(@alignCast(ctx));
                return try s.streams.recv(stream_id, dest);
            }

            fn doStreamClose(ctx: *anyopaque, stream_id: NetStreamId) void {
                const s: *EgressAdapter = @ptrCast(@alignCast(ctx));
                s.streams.close(stream_id);
                s.adapter_metrics.active_connections = s.streams.sessions.count();
            }

            fn doCapturedRecords(ctx: *const anyopaque) []const CapturedExchangeRecord {
                const s: *const EgressAdapter = @ptrCast(@alignCast(ctx));
                return s.event_sink.slice();
            }

            fn doPcapBytes(ctx: *const anyopaque) ?[]const u8 {
                const s: *const EgressAdapter = @ptrCast(@alignCast(ctx));
                if (s.pcap_sink) |*ps| return ps.bytes();
                return null;
            }

            fn doMetrics(ctx: *const anyopaque) AdapterMetrics {
                const s: *const EgressAdapter = @ptrCast(@alignCast(ctx));
                return s.adapter_metrics;
            }

            fn doAdvanceClock(ctx: *anyopaque, delta_ms: u64) void {
                const s: *EgressAdapter = @ptrCast(@alignCast(ctx));
                s.clock_ms += delta_ms;
            }

            fn doSetTransport(ctx: *anyopaque, userdata: ?*anyopaque, handler: CustomTransportFn) void {
                const s: *EgressAdapter = @ptrCast(@alignCast(ctx));
                s.transport_reg.setCustomOverride(userdata, handler);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const s: *EgressAdapter = @ptrCast(@alignCast(ctx));
                const alloc = s.allocator;
                s.deinitInternal();
                alloc.destroy(s);
            }

            const vtable = NetworkAdapter.VTable{
                .execute = &doExecute,
                .connectStream = &doConnectStream,
                .streamSend = &doStreamSend,
                .streamRecv = &doStreamRecv,
                .streamClose = &doStreamClose,
                .capturedRecordsSlice = &doCapturedRecords,
                .pcapBytes = &doPcapBytes,
                .metrics = &doMetrics,
                .advanceClockMs = &doAdvanceClock,
                .setTransportHandler = &doSetTransport,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
