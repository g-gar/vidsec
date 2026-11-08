const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const extensions = @import("flowdata_extensions");

const kernel = flowdata.kernel;
const KernelContext = kernel.KernelContext;
const otel = extensions.opentelemetry;
const OtelSpan = otel.OtelSpan;
const OpenTelemetryExtension = otel.OpenTelemetryExtension;

test "OpenTelemetry: W3C Traceparent Formatting and Parsing" {
    var trace_id: [16]u8 = undefined;
    @memset(&trace_id, 0x4A); // 4a4a...
    var span_id: [8]u8 = undefined;
    @memset(&span_id, 0x2B);  // 2b2b...

    const span = OtelSpan{
        .trace_id = trace_id,
        .span_id = span_id,
        .name = "test_span",
        .start_time_unix_nano = 1000,
        .end_time_unix_nano = 2000,
    };

    const header = span.formatTraceparent();
    try std.testing.expectEqual(@as(usize, 55), header.len);
    try std.testing.expect(std.mem.startsWith(u8, &header, "00-"));
    try std.testing.expect(std.mem.endsWith(u8, &header, "-01"));

    // Verify roundtrip parse
    const parsed = OtelSpan.parseTraceparent(&header);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualSlices(u8, &trace_id, &parsed.?.trace_id);
    try std.testing.expectEqualSlices(u8, &span_id, &parsed.?.span_id);
}

test "OpenTelemetry: TelemetryBus Event Lifecycle, Span Tree, Metrics and OTLP JSON Export" {
    const alloc = std.testing.allocator;

    var k = try KernelContext.init(alloc);
    defer k.deinit();

    var otel_inst = OpenTelemetryExtension.init(alloc, "flowdata-e2e-service");
    defer otel_inst.deinit();

    try k.use(otel_inst.extension());

    var trace_id: [16]u8 = undefined;
    var root_span_id: [8]u8 = undefined;
    var step1_span_id: [8]u8 = undefined;
    var step2_span_id: [8]u8 = undefined;
    @memset(&trace_id, 0x11);
    @memset(&root_span_id, 0x01);
    @memset(&step1_span_id, 0x02);
    @memset(&step2_span_id, 0x03);

    // 1. Pipeline Start
    k.telemetry.emit(.{
        .pipeline_start = .{
            .trace_id = trace_id,
            .span_id = root_span_id,
            .timestamp_ns = 1_000_000,
            .ast = undefined,
            .input_bytes_len = 1024,
        },
    });

    // 2. Step 1 (success)
    k.telemetry.emit(.{
        .step_start = .{
            .trace_id = trace_id,
            .span_id = step1_span_id,
            .parent_span_id = root_span_id,
            .timestamp_ns = 1_100_000,
            .pipeline_name = "main",
            .step_id = "step_triage",
            .module_name = "test_mod",
            .task_name = "test_task",
            .input_count = 1,
        },
    });
    k.telemetry.emit(.{
        .step_end = .{
            .trace_id = trace_id,
            .span_id = step1_span_id,
            .timestamp_ns = 1_500_000,
            .duration_ns = 400_000,
            .pipeline_name = "main",
            .step_id = "step_triage",
            .status = "ok",
            .output_count = 42,
        },
    });

    // 3. Router decision
    var router_span_id: [8]u8 = undefined;
    @memset(&router_span_id, 0x04);
    k.telemetry.emit(.{
        .router_decision = .{
            .trace_id = trace_id,
            .span_id = router_span_id,
            .timestamp_ns = 1_600_000,
            .pipeline_name = "main",
            .router_id = "route_by_severity",
            .matched_expression = "is_suspicious == true",
            .target_pipeline = "quarantine_flow",
        },
    });

    // 4. Step 2 (inside sub-pipeline with error status)
    k.telemetry.emit(.{
        .step_start = .{
            .trace_id = trace_id,
            .span_id = step2_span_id,
            .parent_span_id = root_span_id,
            .timestamp_ns = 1_700_000,
            .pipeline_name = "quarantine_flow",
            .step_id = "step_isolate",
            .module_name = "test_mod",
            .task_name = "test_task",
            .input_count = 1,
        },
    });
    k.telemetry.emit(.{
        .step_end = .{
            .trace_id = trace_id,
            .span_id = step2_span_id,
            .timestamp_ns = 1_900_000,
            .duration_ns = 200_000,
            .pipeline_name = "quarantine_flow",
            .step_id = "step_isolate",
            .status = "error",
            .output_count = 0,
        },
    });

    // 5. Pipeline End
    k.telemetry.emit(.{
        .pipeline_end = .{
            .trace_id = trace_id,
            .span_id = root_span_id,
            .timestamp_ns = 2_000_000,
            .duration_ns = 1_000_000,
            .steps_executed = 2,
            .routers_evaluated = 1,
            .halted_early = true,
            .final_pipeline = "quarantine_flow",
        },
    });

    // Verify Spans were completed
    try std.testing.expectEqual(@as(usize, 4), otel_inst.completed_spans.items.len);

    // Verify Metrics
    try std.testing.expectEqual(@as(u64, 1), otel_inst.metrics_reg.pipelines_executed_total);
    try std.testing.expectEqual(@as(u64, 2), otel_inst.metrics_reg.steps_executed_total);
    try std.testing.expectEqual(@as(u64, 1), otel_inst.metrics_reg.outbound_errors_total);

    // Verify OTLP JSON generation
    const otlp_json_bytes = try otel_inst.toOtlpJson(alloc);
    defer alloc.free(otlp_json_bytes);

    try std.testing.expect(otlp_json_bytes.len > 200);
    try std.testing.expect(std.mem.indexOf(u8, otlp_json_bytes, "\"service.name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, otlp_json_bytes, "flowdata-e2e-service") != null);
    try std.testing.expect(std.mem.indexOf(u8, otlp_json_bytes, "\"step_triage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, otlp_json_bytes, "router:route_by_severity") != null);
    try std.testing.expect(std.mem.indexOf(u8, otlp_json_bytes, "\"pipelines_executed_total\": 1") != null);
}
