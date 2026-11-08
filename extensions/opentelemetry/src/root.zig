const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const kernel = flowdata.kernel;
const KernelContext = kernel.KernelContext;
const Extension = kernel.Extension;
const TelemetryEvent = kernel.TelemetryEvent;
const TelemetrySubscriber = kernel.TelemetrySubscriber;
const RepositoryRegistry = flowdata.RepositoryRegistry;
const PayloadHandle = flowdata.dataflow.PayloadHandle;
const AdapterConfig = flowdata.transport.outbound.contracts.AdapterConfig;
const NetMiddleware = flowdata.transport.outbound.contracts.NetMiddleware;

pub const span = @import("span.zig");
pub const metrics = @import("metrics.zig");
pub const propagation_mw = @import("propagation_mw.zig");
pub const otlp_json = @import("otlp_json.zig");

pub const OtelSpan = span.OtelSpan;
pub const OtelLogRecord = span.OtelLogRecord;
pub const OtelMetricsRegistry = metrics.OtelMetricsRegistry;
pub const OtelTracePropagationMiddleware = propagation_mw.OtelTracePropagationMiddleware;

pub const OpenTelemetryExtension = struct {
    allocator: Allocator,
    service_name: []const u8 = "flowdata",
    completed_spans: std.ArrayListUnmanaged(OtelSpan) = .empty,
    active_spans: std.AutoHashMapUnmanaged([8]u8, OtelSpan) = .empty,
    log_records: std.ArrayListUnmanaged(OtelLogRecord) = .empty,
    metrics_reg: OtelMetricsRegistry = .{},
    export_datasource: ?[]const u8 = null,
    export_file_path: ?[]const u8 = null,

    pub fn init(allocator: Allocator, service_name: []const u8) OpenTelemetryExtension {
        return .{
            .allocator = allocator,
            .service_name = service_name,
        };
    }

    pub fn deinit(self: *OpenTelemetryExtension) void {
        for (self.completed_spans.items) |*s| {
            s.deinit(self.allocator);
        }
        self.completed_spans.deinit(self.allocator);
        self.completed_spans = .empty;

        var ait = self.active_spans.valueIterator();
        while (ait.next()) |s| {
            s.deinit(self.allocator);
        }
        self.active_spans.deinit(self.allocator);
        self.active_spans = .empty;

        for (self.log_records.items) |*l| {
            l.deinit(self.allocator);
        }
        self.log_records.deinit(self.allocator);
        self.log_records = .empty;
    }

    pub fn onEvent(self: *OpenTelemetryExtension, event: *const TelemetryEvent) void {
        switch (event.*) {
            .pipeline_start => |p| {
                const name = self.allocator.dupe(u8, "pipeline_root") catch return;
                const root_span = OtelSpan{
                    .trace_id = p.trace_id,
                    .span_id = p.span_id,
                    .parent_span_id = null,
                    .name = name,
                    .kind = .server,
                    .start_time_unix_nano = p.timestamp_ns,
                    .end_time_unix_nano = 0,
                    .status = .ok,
                };
                self.active_spans.put(self.allocator, p.span_id, root_span) catch {};
            },
            .pipeline_end => |p| {
                if (self.active_spans.fetchRemove(p.span_id)) |entry| {
                    var s = entry.value;
                    s.end_time_unix_nano = p.timestamp_ns;
                    s.status = if (p.halted_early) .error_status else .ok;
                    self.completed_spans.append(self.allocator, s) catch {};
                }
                self.metrics_reg.recordPipeline(p.duration_ns);
            },
            .step_start => |st| {
                const name = self.allocator.dupe(u8, st.step_id) catch return;
                var step_span = OtelSpan{
                    .trace_id = st.trace_id,
                    .span_id = st.span_id,
                    .parent_span_id = st.parent_span_id,
                    .name = name,
                    .kind = .internal,
                    .start_time_unix_nano = st.timestamp_ns,
                    .end_time_unix_nano = 0,
                    .status = .ok,
                };
                const k1 = self.allocator.dupe(u8, "flowdata.pipeline") catch return;
                const v1 = self.allocator.dupe(u8, st.pipeline_name) catch return;
                step_span.attributes.append(self.allocator, .{ .key = k1, .value = v1 }) catch {};

                const k2 = self.allocator.dupe(u8, "flowdata.step_id") catch return;
                const v2 = self.allocator.dupe(u8, st.step_id) catch return;
                step_span.attributes.append(self.allocator, .{ .key = k2, .value = v2 }) catch {};

                self.active_spans.put(self.allocator, st.span_id, step_span) catch {};
            },
            .step_end => |se| {
                const is_err = !std.mem.eql(u8, se.status, "ok");
                if (self.active_spans.fetchRemove(se.span_id)) |entry| {
                    var s = entry.value;
                    s.end_time_unix_nano = se.timestamp_ns;
                    s.status = if (is_err) .error_status else .ok;
                    self.completed_spans.append(self.allocator, s) catch {};
                }
                self.metrics_reg.recordStep(is_err);
            },
            .router_decision => |rd| {
                const name = std.fmt.allocPrint(self.allocator, "router:{s}", .{rd.router_id}) catch return;
                var r_span = OtelSpan{
                    .trace_id = rd.trace_id,
                    .span_id = rd.span_id,
                    .parent_span_id = null,
                    .name = name,
                    .kind = .internal,
                    .start_time_unix_nano = rd.timestamp_ns,
                    .end_time_unix_nano = rd.timestamp_ns,
                    .status = .ok,
                };
                if (rd.matched_expression) |expr| {
                    const k = self.allocator.dupe(u8, "flowdata.router_matched") catch return;
                    const v = self.allocator.dupe(u8, expr) catch return;
                    r_span.attributes.append(self.allocator, .{ .key = k, .value = v }) catch {};
                }
                if (rd.target_pipeline) |target| {
                    const k = self.allocator.dupe(u8, "flowdata.target_pipeline") catch return;
                    const v = self.allocator.dupe(u8, target) catch return;
                    r_span.attributes.append(self.allocator, .{ .key = k, .value = v }) catch {};
                }
                self.completed_spans.append(self.allocator, r_span) catch {};
            },
            .task_log => |tl| {
                const sev = switch (tl.level) {
                    0 => self.allocator.dupe(u8, "DEBUG") catch return,
                    1 => self.allocator.dupe(u8, "INFO") catch return,
                    2 => self.allocator.dupe(u8, "WARN") catch return,
                    else => self.allocator.dupe(u8, "ERROR") catch return,
                };
                const msg = self.allocator.dupe(u8, tl.message) catch return;
                self.log_records.append(self.allocator, .{
                    .timestamp_ns = 0,
                    .trace_id = tl.trace_id,
                    .span_id = tl.span_id,
                    .severity = sev,
                    .body = msg,
                }) catch {};
            },
            else => {},
        }
    }

    pub fn toOtlpJson(self: *const OpenTelemetryExtension, allocator: Allocator) ![]u8 {
        return otlp_json.serializeOtlpJson(
            allocator,
            self.service_name,
            self.completed_spans.items,
            self.log_records.items,
            &self.metrics_reg,
        );
    }

    pub fn flush(self: *OpenTelemetryExtension, repos: *RepositoryRegistry) anyerror!void {
        if (self.export_datasource != null or self.export_file_path != null) {
            const json_bytes = try self.toOtlpJson(self.allocator);
            defer self.allocator.free(json_bytes);

            if (self.export_datasource) |ds_name| {
                if (repos.get(ds_name)) |repo| {
                    const handle = PayloadHandle.fromSlice(u8, json_bytes);
                    try repo.writePayload("otel_telemetry", handle);
                }
            }

            if (self.export_file_path) |path| {
                try flowdata.writeFileBytes(self.allocator, path, json_bytes);
            }
        }
    }

    pub fn subscriber(self: *OpenTelemetryExtension) TelemetrySubscriber {
        const Trampoline = struct {
            fn doOnEvent(ctx: *anyopaque, event: *const TelemetryEvent) void {
                const s: *OpenTelemetryExtension = @ptrCast(@alignCast(ctx));
                s.onEvent(event);
            }

            fn doFlush(ctx: *anyopaque, repos: *RepositoryRegistry) anyerror!void {
                const s: *OpenTelemetryExtension = @ptrCast(@alignCast(ctx));
                try s.flush(repos);
            }

            const vtable = TelemetrySubscriber.VTable{
                .onEvent = &doOnEvent,
                .flush = &doFlush,
                .deinit = null,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }

    pub fn extension(self: *OpenTelemetryExtension) Extension {
        const Trampoline = struct {
            fn getName(_: *const anyopaque) []const u8 {
                return "flowdata.opentelemetry";
            }

            fn register(ctx_ptr: *anyopaque, k: *KernelContext) anyerror!void {
                const s: *OpenTelemetryExtension = @ptrCast(@alignCast(ctx_ptr));
                try k.telemetry.subscribe(s.subscriber());

                const mw_factory = struct {
                    var otel_ref: *OpenTelemetryExtension = undefined;
                    fn factory(alloc: Allocator, _: AdapterConfig) anyerror!?NetMiddleware {
                        return try OtelTracePropagationMiddleware.createHeap(alloc, &otel_ref.metrics_reg);
                    }
                };
                mw_factory.otel_ref = s;
                try k.outbound.registerMiddlewareFactory(&mw_factory.factory);
            }

            fn deinitExt(ctx_ptr: *anyopaque, _: Allocator) void {
                const s: *OpenTelemetryExtension = @ptrCast(@alignCast(ctx_ptr));
                s.deinit();
            }

            const vtable = Extension.VTable{
                .name = &getName,
                .register = &register,
                .deinit = &deinitExt,
            };
        };
        return .{
            .ptr = self,
            .vtable = &Trampoline.vtable,
        };
    }
};

var global_otel_instance: ?OpenTelemetryExtension = null;

pub fn getGlobalOtel(allocator: Allocator) *OpenTelemetryExtension {
    if (global_otel_instance == null) {
        global_otel_instance = OpenTelemetryExtension.init(allocator, "flowdata-service");
    }
    return &global_otel_instance.?;
}

pub const extension = Extension.fromStateless("flowdata.opentelemetry", struct {
    fn reg(k: *KernelContext) anyerror!void {
        const ext = getGlobalOtel(k.allocator);
        try k.use(ext.extension());
    }
}.reg);
