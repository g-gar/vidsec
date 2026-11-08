const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const sinks = @import("../sinks/mod.zig");

const NetworkAdapter = contracts.NetworkAdapter;
const AdapterConfig = contracts.AdapterConfig;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const NetStreamId = contracts.NetStreamId;
const CapturedExchangeRecord = contracts.CapturedExchangeRecord;
const AdapterMetrics = contracts.AdapterMetrics;
const Uri = contracts.Uri;
const CustomTransportFn = contracts.CustomTransportFn;
const MemoryEventSink = sinks.MemoryEventSink;

/// Air-Gapped Network Adapter (`driver: none`).
/// Implements `NetworkAdapter` VTable with zero outbound transport capabilities; immediately blocks all exchanges.
pub const IsolatedAdapter = struct {
    comptime {
        NetworkAdapter.assertImplements(@This());
    }

    allocator: Allocator,
    id: []const u8,
    event_sink: MemoryEventSink,
    adapter_metrics: AdapterMetrics = .{},
    clock_ms: u64 = 1000,

    pub fn createHeap(
        allocator: Allocator,
        config: AdapterConfig,
        _: @import("mod.zig").AdapterDriverContext,
    ) anyerror!NetworkAdapter {
        const self = try allocator.create(IsolatedAdapter);
        self.* = .{
            .allocator = allocator,
            .id = config.id,
            .event_sink = MemoryEventSink.init(allocator),
        };
        return self.networkAdapter();
    }

    pub fn execute(
        self: *IsolatedAdapter,
        raw_url: []const u8,
        operation: []const u8,
        body: []const u8,
        trace_tag: []const u8,
    ) NetError!NetResult {
        const uri = Uri.parse(raw_url) orelse return error.InvalidUri;
        self.adapter_metrics.requests_blocked += 1;

        const ex = NetExchange{
            .allocator = self.allocator,
            .adapter_id = self.id,
            .trace_tag = trace_tag,
            .now_ms = self.clock_ms,
            .original_url = raw_url,
            .effective_url = raw_url,
            .uri = uri,
            .operation = operation,
            .req_body = body,
            .metrics = &self.adapter_metrics,
        };
        const blocked_res = NetResult{
            .status_code = 0,
            .effective_url = raw_url,
            .verdict = .blocked,
        };
        self.event_sink.onExchange(&ex, &blocked_res) catch return error.OutOfMemory;
        return error.NetworkPolicyDenied;
    }

    pub fn networkAdapter(self: *IsolatedAdapter) NetworkAdapter {
        const Trampoline = struct {
            fn doExecute(
                ctx: *anyopaque,
                raw_url: []const u8,
                operation: []const u8,
                body: []const u8,
                trace_tag: []const u8,
            ) NetError!NetResult {
                const s: *IsolatedAdapter = @ptrCast(@alignCast(ctx));
                return try s.execute(raw_url, operation, body, trace_tag);
            }

            fn doConnectStream(
                ctx: *anyopaque,
                raw_url: []const u8,
                operation: []const u8,
                trace_tag: []const u8,
            ) NetError!NetStreamId {
                const s: *IsolatedAdapter = @ptrCast(@alignCast(ctx));
                _ = try s.execute(raw_url, operation, "", trace_tag);
                return error.NetworkPolicyDenied;
            }

            fn doStreamSend(_: *anyopaque, _: NetStreamId, _: []const u8) NetError!usize {
                return error.NetworkPolicyDenied;
            }

            fn doStreamRecv(_: *anyopaque, _: NetStreamId, _: []u8) NetError!usize {
                return error.NetworkPolicyDenied;
            }

            fn doStreamClose(_: *anyopaque, _: NetStreamId) void {}

            fn doCapturedRecords(ctx: *const anyopaque) []const CapturedExchangeRecord {
                const s: *const IsolatedAdapter = @ptrCast(@alignCast(ctx));
                return s.event_sink.slice();
            }

            fn doPcapBytes(_: *const anyopaque) ?[]const u8 {
                return null;
            }

            fn doMetrics(ctx: *const anyopaque) AdapterMetrics {
                const s: *const IsolatedAdapter = @ptrCast(@alignCast(ctx));
                return s.adapter_metrics;
            }

            fn doAdvanceClock(ctx: *anyopaque, delta_ms: u64) void {
                const s: *IsolatedAdapter = @ptrCast(@alignCast(ctx));
                s.clock_ms += delta_ms;
            }

            fn doSetTransport(_: *anyopaque, _: ?*anyopaque, _: CustomTransportFn) void {}

            fn doDeinit(ctx: *anyopaque) void {
                const s: *IsolatedAdapter = @ptrCast(@alignCast(ctx));
                const alloc = s.allocator;
                s.event_sink.deinitInternal();
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
