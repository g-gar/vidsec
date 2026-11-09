const std = @import("std");
const exchange_mod = @import("exchange.zig");
const NetResult = exchange_mod.NetResult;
const NetError = exchange_mod.NetError;
const NetStreamId = exchange_mod.NetStreamId;
const CapturedExchangeRecord = exchange_mod.CapturedExchangeRecord;
const AdapterMetrics = exchange_mod.AdapterMetrics;
const HttpHeader = exchange_mod.HttpHeader;
const TransportHandlerFn = @import("transport.zig").CustomTransportFn;

/// Polymorphic abstract interface for Virtual Network Adapters (`none`, `ingress_only`, `egress`, `sinkhole`, etc.).
/// Completely decoupled from pipeline step/task concepts.
pub const NetworkAdapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (
            ctx: *anyopaque,
            raw_url: []const u8,
            operation: []const u8,
            headers: []const HttpHeader,
            body: []const u8,
            trace_tag: []const u8,
        ) NetError!NetResult,
        connectStream: *const fn (
            ctx: *anyopaque,
            raw_url: []const u8,
            operation: []const u8,
            trace_tag: []const u8,
        ) NetError!NetStreamId,
        streamSend: *const fn (ctx: *anyopaque, stream_id: NetStreamId, payload: []const u8) NetError!usize,
        streamRecv: *const fn (ctx: *anyopaque, stream_id: NetStreamId, dest: []u8) NetError!usize,
        streamClose: *const fn (ctx: *anyopaque, stream_id: NetStreamId) void,
        capturedRecordsSlice: *const fn (ctx: *const anyopaque) []const CapturedExchangeRecord,
        pcapBytes: *const fn (ctx: *const anyopaque) ?[]const u8,
        metrics: *const fn (ctx: *const anyopaque) AdapterMetrics,
        advanceClockMs: *const fn (ctx: *anyopaque, delta_ms: u64) void,
        setTransportHandler: *const fn (ctx: *anyopaque, userdata: ?*anyopaque, handler: TransportHandlerFn) void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub const NetworkAdapterVTable = VTable;

    pub fn execute(
        self: NetworkAdapter,
        raw_url: []const u8,
        operation: []const u8,
        headers: []const HttpHeader,
        body: []const u8,
        trace_tag: []const u8,
    ) NetError!NetResult {
        return try self.vtable.execute(self.ptr, raw_url, operation, headers, body, trace_tag);
    }

    pub fn connectStream(
        self: NetworkAdapter,
        raw_url: []const u8,
        operation: []const u8,
        trace_tag: []const u8,
    ) NetError!NetStreamId {
        return try self.vtable.connectStream(self.ptr, raw_url, operation, trace_tag);
    }

    pub fn streamSend(self: NetworkAdapter, stream_id: NetStreamId, payload: []const u8) NetError!usize {
        return try self.vtable.streamSend(self.ptr, stream_id, payload);
    }

    pub fn streamRecv(self: NetworkAdapter, stream_id: NetStreamId, dest: []u8) NetError!usize {
        return try self.vtable.streamRecv(self.ptr, stream_id, dest);
    }

    pub fn streamClose(self: NetworkAdapter, stream_id: NetStreamId) void {
        self.vtable.streamClose(self.ptr, stream_id);
    }

    pub fn capturedRecordsSlice(self: NetworkAdapter) []const CapturedExchangeRecord {
        return self.vtable.capturedRecordsSlice(self.ptr);
    }

    pub fn pcapBytes(self: NetworkAdapter) ?[]const u8 {
        return self.vtable.pcapBytes(self.ptr);
    }

    pub fn metrics(self: NetworkAdapter) AdapterMetrics {
        return self.vtable.metrics(self.ptr);
    }

    pub fn advanceClockMs(self: NetworkAdapter, delta_ms: u64) void {
        self.vtable.advanceClockMs(self.ptr, delta_ms);
    }

    pub fn setTransportHandler(self: NetworkAdapter, userdata: ?*anyopaque, handler: TransportHandlerFn) void {
        self.vtable.setTransportHandler(self.ptr, userdata, handler);
    }

    pub fn deinit(self: NetworkAdapter) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "networkAdapter") and !@hasDecl(T, "outboundAdapter")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn outboundAdapter(*" ++ @typeName(T) ++ ") OutboundAdapter'");
            }
        }
    }
};

/// Canonical Outbound Adapter contract alias
pub const OutboundAdapter = NetworkAdapter;
