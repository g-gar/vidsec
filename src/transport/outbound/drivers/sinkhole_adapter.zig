const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const strategies = @import("../strategies/mod.zig");
const middleware = @import("../middleware/mod.zig");
const sinks = @import("../sinks/mod.zig");
const transports = @import("../protocols/mod.zig");

const NetworkAdapter = contracts.NetworkAdapter;
const AdapterConfig = contracts.AdapterConfig;
const MiddlewareChain = contracts.MiddlewareChain;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const NetStreamId = contracts.NetStreamId;
const CapturedExchangeRecord = contracts.CapturedExchangeRecord;
const AdapterMetrics = contracts.AdapterMetrics;
const PacketSink = contracts.PacketSink;
const Uri = contracts.Uri;
const CustomTransportFn = contracts.CustomTransportFn;

const RedirectMiddleware = middleware.RedirectMiddleware;
const CaptureMiddleware = middleware.CaptureMiddleware;
const PolicyGuardMiddleware = middleware.PolicyGuardMiddleware;
const MemoryEventSink = sinks.MemoryEventSink;
const MockSinkholeTransport = transports.MockSinkholeTransport;
const StreamSessionTable = transports.StreamSessionTable;

/// Forensic Sinkhole Network Adapter (`driver: sinkhole`).
/// Assembles `[RedirectMiddleware, CaptureMiddleware, PolicyGuardMiddleware]` -> `MockSinkholeTransport`.
/// Intercepts all traffic 100% offline, records packets/events, and optionally emulates synthetic responses.
pub const SinkholeAdapter = struct {
    comptime {
        NetworkAdapter.assertImplements(@This());
    }

    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    config: AdapterConfig,
    chain: MiddlewareChain,
    mock_transport: MockSinkholeTransport,
    streams: StreamSessionTable,
    event_sink: MemoryEventSink,
    captured_packet_sink: ?PacketSink = null,
    adapter_metrics: AdapterMetrics = .{},
    clock_ms: u64 = 1000,

    pub fn createHeap(
        allocator: Allocator,
        config: AdapterConfig,
        ctx: @import("mod.zig").AdapterDriverContext,
    ) anyerror!NetworkAdapter {
        const self = try allocator.create(SinkholeAdapter);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .config = config,
            .chain = MiddlewareChain.init(allocator),
            .mock_transport = .{ .emulate_responses = config.emulate_responses },
            .streams = StreamSessionTable.init(allocator),
            .event_sink = MemoryEventSink.init(allocator),
            .captured_packet_sink = null,
        };
        errdefer self.deinitInternal();

        // 1. URL Redirects (if any)
        if (config.redirects.len > 0) {
            try self.chain.use(try RedirectMiddleware.createHeap(allocator, config.redirects));
        }

        // 2. Packet & Event Capture observer
        var active_sinks: std.ArrayListUnmanaged(PacketSink) = .empty;
        defer active_sinks.deinit(allocator);
        try active_sinks.append(allocator, self.event_sink.packetSink());
        for (ctx.extra_sinks) |sink_factory| {
            if (try sink_factory(allocator, config)) |extra_sink| {
                if (extra_sink.vtable.getBytes != null and self.captured_packet_sink == null) {
                    self.captured_packet_sink = extra_sink;
                }
                try active_sinks.append(allocator, extra_sink);
            }
        }
        try self.chain.use(try CaptureMiddleware.createHeap(allocator, active_sinks.items));

        // 3. Policy Guard (if explicit allow_rules configured on the sinkhole)
        if (config.policy.allow_rules.len > 0) {
            const pol_rule = try strategies.CompositePolicy.createFromSpec(allocator, config);
            try self.chain.use(try PolicyGuardMiddleware.createHeap(allocator, pol_rule));
        }

        // 4. Extra middlewares
        for (ctx.extra_middlewares) |mw_factory| {
            if (try mw_factory(allocator, config)) |mw| {
                try self.chain.use(mw);
            }
        }

        return self.networkAdapter();
    }

    pub fn deinitInternal(self: *SinkholeAdapter) void {
        self.streams.deinit();
        self.chain.deinit();
        self.event_sink.deinitInternal();
        self.arena.deinit();
    }

    pub fn execute(
        self: *SinkholeAdapter,
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
            .metrics = &self.adapter_metrics,
        };

        const res = try self.chain.execute(&ex, self.mock_transport.dispatcher());
        if (!self.config.emulate_responses) {
            return error.NetworkPolicyDenied;
        }
        return res;
    }

    pub fn connectStream(
        self: *SinkholeAdapter,
        raw_url: []const u8,
        operation: []const u8,
        trace_tag: []const u8,
    ) NetError!NetStreamId {
        const res = try self.execute(raw_url, operation, "", trace_tag);
        const uri = Uri.parse(res.effective_url) orelse Uri.parse(raw_url) orelse return error.InvalidUri;
        return try self.streams.openSession(uri.scheme, res.effective_url, res.proxy_used, res.body);
    }

    pub fn networkAdapter(self: *SinkholeAdapter) NetworkAdapter {
        const Trampoline = struct {
            fn doExecute(
                ctx: *anyopaque,
                raw_url: []const u8,
                operation: []const u8,
                body: []const u8,
                trace_tag: []const u8,
            ) NetError!NetResult {
                const s: *SinkholeAdapter = @ptrCast(@alignCast(ctx));
                return try s.execute(raw_url, operation, body, trace_tag);
            }

            fn doConnectStream(
                ctx: *anyopaque,
                raw_url: []const u8,
                operation: []const u8,
                trace_tag: []const u8,
            ) NetError!NetStreamId {
                const s: *SinkholeAdapter = @ptrCast(@alignCast(ctx));
                return try s.connectStream(raw_url, operation, trace_tag);
            }

            fn doStreamSend(ctx: *anyopaque, stream_id: NetStreamId, payload: []const u8) NetError!usize {
                const s: *SinkholeAdapter = @ptrCast(@alignCast(ctx));
                return try s.streams.send(stream_id, payload);
            }

            fn doStreamRecv(ctx: *anyopaque, stream_id: NetStreamId, dest: []u8) NetError!usize {
                const s: *SinkholeAdapter = @ptrCast(@alignCast(ctx));
                return try s.streams.recv(stream_id, dest);
            }

            fn doStreamClose(ctx: *anyopaque, stream_id: NetStreamId) void {
                const s: *SinkholeAdapter = @ptrCast(@alignCast(ctx));
                s.streams.close(stream_id);
            }

            fn doCapturedRecords(ctx: *const anyopaque) []const CapturedExchangeRecord {
                const s: *const SinkholeAdapter = @ptrCast(@alignCast(ctx));
                return s.event_sink.slice();
            }

            fn doPcapBytes(ctx: *const anyopaque) ?[]const u8 {
                const s: *const SinkholeAdapter = @ptrCast(@alignCast(ctx));
                if (s.captured_packet_sink) |sink| return sink.getBytes();
                return null;
            }

            fn doMetrics(ctx: *const anyopaque) AdapterMetrics {
                const s: *const SinkholeAdapter = @ptrCast(@alignCast(ctx));
                return s.adapter_metrics;
            }

            fn doAdvanceClock(ctx: *anyopaque, delta_ms: u64) void {
                const s: *SinkholeAdapter = @ptrCast(@alignCast(ctx));
                s.clock_ms += delta_ms;
            }

            fn doSetTransport(_: *anyopaque, _: ?*anyopaque, _: CustomTransportFn) void {}

            fn doDeinit(ctx: *anyopaque) void {
                const s: *SinkholeAdapter = @ptrCast(@alignCast(ctx));
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

    pub const outboundAdapter = networkAdapter;
};
