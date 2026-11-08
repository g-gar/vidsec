const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TraceId = [16]u8;
pub const SpanId = [8]u8;

pub const SpanKind = enum {
    internal,
    server,
    client,
    producer,
    consumer,
};

pub const SpanStatus = enum {
    unset,
    ok,
    error_status,
};

pub const KeyValueAttribute = struct {
    key: []const u8,
    value: []const u8,
};

pub const OtelSpan = struct {
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: ?SpanId = null,
    name: []const u8,
    kind: SpanKind = .internal,
    start_time_unix_nano: u64,
    end_time_unix_nano: u64,
    status: SpanStatus = .ok,
    attributes: std.ArrayListUnmanaged(KeyValueAttribute) = .empty,

    pub fn deinit(self: *OtelSpan, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.attributes.items) |attr| {
            allocator.free(attr.key);
            allocator.free(attr.value);
        }
        self.attributes.deinit(allocator);
    }

    /// Formats this span's trace context as an official W3C `traceparent` header:
    /// `00-<32 hex trace_id>-<16 hex span_id>-01` (length: 55 bytes).
    pub fn formatTraceparent(self: OtelSpan) [55]u8 {
        var buf: [55]u8 = undefined;
        buf[0] = '0';
        buf[1] = '0';
        buf[2] = '-';
        const trace_hex = std.fmt.bytesToHex(self.trace_id, .lower);
        @memcpy(buf[3..35], &trace_hex);
        buf[35] = '-';
        const span_hex = std.fmt.bytesToHex(self.span_id, .lower);
        @memcpy(buf[36..52], &span_hex);
        buf[52] = '-';
        buf[53] = '0';
        buf[54] = '1';
        return buf;
    }

    pub fn parseTraceparent(header: []const u8) ?struct { trace_id: TraceId, span_id: SpanId } {
        if (header.len != 55) return null;
        if (!std.mem.eql(u8, header[0..3], "00-")) return null;
        if (header[35] != '-' or header[52] != '-') return null;

        var trace: TraceId = undefined;
        _ = std.fmt.hexToBytes(&trace, header[3..35]) catch return null;

        var span: SpanId = undefined;
        _ = std.fmt.hexToBytes(&span, header[36..52]) catch return null;

        return .{ .trace_id = trace, .span_id = span };
    }
};

pub const OtelLogRecord = struct {
    timestamp_ns: u64,
    trace_id: ?TraceId = null,
    span_id: ?SpanId = null,
    severity: []const u8,
    body: []const u8,

    pub fn deinit(self: *OtelLogRecord, allocator: Allocator) void {
        allocator.free(self.severity);
        allocator.free(self.body);
    }
};
