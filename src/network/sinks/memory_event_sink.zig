const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const PacketSink = contracts.PacketSink;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const CapturedExchangeRecord = contracts.CapturedExchangeRecord;

/// Domain-agnostic in-memory structured telemetry sink recording `CapturedExchangeRecord` items.
/// Implements the polymorphic `PacketSink` VTable with zero coupling to pipeline step/task concepts.
pub const MemoryEventSink = struct {
    comptime {
        PacketSink.assertImplements(@This());
    }

    arena: std.heap.ArenaAllocator,
    records: std.ArrayListUnmanaged(CapturedExchangeRecord) = .empty,
    next_seq_id: u64 = 1,

    pub fn init(allocator: Allocator) MemoryEventSink {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinitInternal(self: *MemoryEventSink) void {
        self.arena.deinit();
    }

    pub fn slice(self: *const MemoryEventSink) []const CapturedExchangeRecord {
        return self.records.items;
    }

    pub fn onExchange(self: *MemoryEventSink, exchange: *const NetExchange, result: *const NetResult) !void {
        const a = self.arena.allocator();
        const seq_id = self.next_seq_id;
        self.next_seq_id += 1;

        try self.records.append(a, .{
            .sequence_id = seq_id,
            .timestamp_ms = exchange.now_ms,
            .trace_tag = try a.dupe(u8, exchange.trace_tag),
            .scheme = try a.dupe(u8, exchange.uri.scheme),
            .operation = try a.dupe(u8, exchange.operation),
            .dst_host = try a.dupe(u8, exchange.uri.host),
            .dst_port = exchange.uri.port,
            .resource = try a.dupe(u8, exchange.uri.resource),
            .proxy_used = try a.dupe(u8, result.proxy_used),
            .status_code = result.status_code,
            .latency_ms = result.latency_ms,
            .verdict = result.verdict,
        });
    }

    pub fn packetSink(self: *MemoryEventSink) PacketSink {
        const Trampoline = struct {
            fn doOnExchange(ctx: *anyopaque, exchange: *const NetExchange, result: *const NetResult) anyerror!void {
                const s: *MemoryEventSink = @ptrCast(@alignCast(ctx));
                try s.onExchange(exchange, result);
            }

            fn doOnTlsSecret(_: *anyopaque, _: []const u8) anyerror!void {}

            fn doDeinit(ctx: *anyopaque, _: Allocator) void {
                const s: *MemoryEventSink = @ptrCast(@alignCast(ctx));
                s.deinitInternal();
            }

            const vtable = PacketSink.VTable{
                .onExchange = &doOnExchange,
                .onTlsSecret = &doOnTlsSecret,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
