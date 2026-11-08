const std = @import("std");
const Allocator = std.mem.Allocator;
const span_mod = @import("span.zig");
const metrics_mod = @import("metrics.zig");

pub fn serializeOtlpJson(
    allocator: Allocator,
    service_name: []const u8,
    spans: []const span_mod.OtelSpan,
    logs: []const span_mod.OtelLogRecord,
    metrics: *const metrics_mod.OtelMetricsRegistry,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\n  \"resourceSpans\": [\n    {\n      \"resource\": {\n        \"attributes\": [\n          {\"key\": \"service.name\", \"value\": {\"stringValue\": \"");
    try out.appendSlice(allocator, service_name);
    try out.appendSlice(allocator, "\"}}\n        ]\n      },\n      \"scopeSpans\": [\n        {\n          \"scope\": {\"name\": \"flowdata.core\"},\n          \"spans\": [\n");

    for (spans, 0..) |s, idx| {
        const trace_hex = std.fmt.bytesToHex(s.trace_id, .lower);
        const span_hex = std.fmt.bytesToHex(s.span_id, .lower);

        try out.appendSlice(allocator, "            {\n              \"traceId\": \"");
        try out.appendSlice(allocator, &trace_hex);
        try out.appendSlice(allocator, "\",\n              \"spanId\": \"");
        try out.appendSlice(allocator, &span_hex);
        try out.appendSlice(allocator, "\"");

        if (s.parent_span_id) |pid| {
            const parent_hex = std.fmt.bytesToHex(pid, .lower);
            try out.appendSlice(allocator, ",\n              \"parentSpanId\": \"");
            try out.appendSlice(allocator, &parent_hex);
            try out.appendSlice(allocator, "\"");
        }

        try out.appendSlice(allocator, ",\n              \"name\": \"");
        try out.appendSlice(allocator, s.name);
        try out.appendSlice(allocator, "\",\n              \"kind\": ");
        try appendUint(&out, allocator, @intFromEnum(s.kind) + 1);
        try out.appendSlice(allocator, ",\n              \"startTimeUnixNano\": ");
        try appendU64(&out, allocator, s.start_time_unix_nano);
        try out.appendSlice(allocator, ",\n              \"endTimeUnixNano\": ");
        try appendU64(&out, allocator, s.end_time_unix_nano);
        try out.appendSlice(allocator, ",\n              \"status\": {\"code\": ");
        try appendUint(&out, allocator, switch (s.status) {
            .unset => 0,
            .ok => 1,
            .error_status => 2,
        });
        try out.appendSlice(allocator, "},\n              \"attributes\": [");

        for (s.attributes.items, 0..) |attr, a_idx| {
            try out.appendSlice(allocator, "{\"key\":\"");
            try out.appendSlice(allocator, attr.key);
            try out.appendSlice(allocator, "\",\"value\":{\"stringValue\":\"");
            try out.appendSlice(allocator, attr.value);
            try out.appendSlice(allocator, "\"}}");
            if (a_idx + 1 < s.attributes.items.len) {
                try out.appendSlice(allocator, ",");
            }
        }

        try out.appendSlice(allocator, "]\n            }");
        if (idx + 1 < spans.len) {
            try out.appendSlice(allocator, ",");
        }
        try out.appendSlice(allocator, "\n");
    }

    try out.appendSlice(allocator, "          ]\n        }\n      ]\n    }\n  ],\n  \"resourceLogs\": [\n    {\n      \"scopeLogs\": [\n        {\n          \"logRecords\": [\n");

    for (logs, 0..) |l, idx| {
        try out.appendSlice(allocator, "            {\n              \"timeUnixNano\": ");
        try appendU64(&out, allocator, l.timestamp_ns);
        try out.appendSlice(allocator, ",\n              \"severityText\": \"");
        try out.appendSlice(allocator, l.severity);
        try out.appendSlice(allocator, "\",\n              \"body\": {\"stringValue\": \"");
        try out.appendSlice(allocator, l.body);
        try out.appendSlice(allocator, "\"}\n            }");
        if (idx + 1 < logs.len) {
            try out.appendSlice(allocator, ",");
        }
        try out.appendSlice(allocator, "\n");
    }

    try out.appendSlice(allocator, "          ]\n        }\n      ]\n    }\n  ],\n  \"metrics\": {\n    \"pipelines_executed_total\": ");
    try appendU64(&out, allocator, metrics.pipelines_executed_total);
    try out.appendSlice(allocator, ",\n    \"steps_executed_total\": ");
    try appendU64(&out, allocator, metrics.steps_executed_total);
    try out.appendSlice(allocator, ",\n    \"outbound_requests_total\": ");
    try appendU64(&out, allocator, metrics.outbound_requests_total);
    try out.appendSlice(allocator, ",\n    \"outbound_errors_total\": ");
    try appendU64(&out, allocator, metrics.outbound_errors_total);
    try out.appendSlice(allocator, ",\n    \"total_pipeline_duration_ns\": ");
    try appendU64(&out, allocator, metrics.total_pipeline_duration_ns);
    try out.appendSlice(allocator, "\n  }\n}\n");

    return out.toOwnedSlice(allocator);
}

fn appendUint(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, v: usize) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

fn appendU64(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, v: u64) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    try buf.appendSlice(allocator, s);
}
