const std = @import("std");

/// OpenTelemetry metrics registry for aggregated pipeline execution and network telemetry.
pub const OtelMetricsRegistry = struct {
    pipelines_executed_total: u64 = 0,
    steps_executed_total: u64 = 0,
    rows_processed_total: u64 = 0,
    rows_filtered_out_total: u64 = 0,
    outbound_requests_total: u64 = 0,
    outbound_errors_total: u64 = 0,
    total_pipeline_duration_ns: u64 = 0,

    pub fn recordPipeline(self: *OtelMetricsRegistry, duration_ns: u64) void {
        self.pipelines_executed_total += 1;
        self.total_pipeline_duration_ns += duration_ns;
    }

    pub fn recordStep(self: *OtelMetricsRegistry, has_error: bool) void {
        self.steps_executed_total += 1;
        if (has_error) {
            self.outbound_errors_total += 1;
        }
    }

    pub fn recordOutbound(self: *OtelMetricsRegistry, has_error: bool) void {
        self.outbound_requests_total += 1;
        if (has_error) {
            self.outbound_errors_total += 1;
        }
    }
};
