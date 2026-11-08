const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const kernel = flowdata.kernel;
const TelemetryEvent = kernel.TelemetryEvent;
const TelemetrySubscriber = kernel.TelemetrySubscriber;
const KernelContext = kernel.KernelContext;
const Extension = kernel.Extension;

pub const LogLevel = enum(u32) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

pub const TaskStatus = enum(i32) {
    ok = 0,
    recoverable_warning = 1,
    halt_pipeline = 2,
    fatal_error = -1,
};

pub const LogLevel_ABI = LogLevel;
pub const TaskStatus_ABI = TaskStatus;

pub const TraceEvent = union(enum) {
    step_start: struct {
        seq: usize,
        pipeline: []const u8,
        step: []const u8,
    },
    task_log: struct {
        seq: usize,
        pipeline: []const u8,
        step: []const u8,
        level: LogLevel_ABI,
        message: []const u8,
    },
    step_end: struct {
        seq: usize,
        pipeline: []const u8,
        step: []const u8,
        status: TaskStatus_ABI,
        windows_read: usize,
        rows_read: usize,
        rows_emitted: usize,
    },
    router_decision: struct {
        seq: usize,
        pipeline: []const u8,
        router: []const u8,
        target_pipeline: ?[]const u8,
    },
};

pub const DebugAction = enum {
    continue_run,
    abort_run,
};

pub const DebugController = struct {
    userdata: ?*anyopaque = null,
    on_after_step: ?*const fn (
        userdata: ?*anyopaque,
        pipeline_name: []const u8,
        step_name: []const u8,
    ) DebugAction = null,

    pub fn notifyAfterStep(self: DebugController, pipeline_name: []const u8, step_name: []const u8) DebugAction {
        if (self.on_after_step) |cb| {
            return cb(self.userdata, pipeline_name, step_name);
        }
        return .continue_run;
    }
};

/// Collects structured execution events outside SQLite and serializes them to JSON Lines (`.jsonl`).
pub const ExecutionTracer = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayListUnmanaged(TraceEvent) = .empty,
    next_seq: usize = 1,

    pub fn init(backing_allocator: Allocator) ExecutionTracer {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *ExecutionTracer) void {
        self.arena.deinit();
    }

    pub fn recordStepStart(self: *ExecutionTracer, pipeline: []const u8, step: []const u8) !usize {
        const a = self.arena.allocator();
        const seq = self.next_seq;
        self.next_seq += 1;
        try self.events.append(a, .{
            .step_start = .{
                .seq = seq,
                .pipeline = try a.dupe(u8, pipeline),
                .step = try a.dupe(u8, step),
            },
        });
        return seq;
    }

    pub fn recordTaskLog(
        self: *ExecutionTracer,
        seq: usize,
        pipeline: []const u8,
        step: []const u8,
        level: LogLevel_ABI,
        message: []const u8,
    ) !void {
        const a = self.arena.allocator();
        try self.events.append(a, .{
            .task_log = .{
                .seq = seq,
                .pipeline = try a.dupe(u8, pipeline),
                .step = try a.dupe(u8, step),
                .level = level,
                .message = try a.dupe(u8, message),
            },
        });
    }

    pub fn recordStepEnd(
        self: *ExecutionTracer,
        seq: usize,
        pipeline: []const u8,
        step: []const u8,
        status: TaskStatus_ABI,
        windows_read: usize,
        rows_read: usize,
        rows_emitted: usize,
    ) !void {
        const a = self.arena.allocator();
        try self.events.append(a, .{
            .step_end = .{
                .seq = seq,
                .pipeline = try a.dupe(u8, pipeline),
                .step = try a.dupe(u8, step),
                .status = status,
                .windows_read = windows_read,
                .rows_read = rows_read,
                .rows_emitted = rows_emitted,
            },
        });
    }

    pub fn recordRouterDecision(
        self: *ExecutionTracer,
        pipeline: []const u8,
        router: []const u8,
        target_pipeline: ?[]const u8,
    ) !void {
        const a = self.arena.allocator();
        const seq = self.next_seq;
        self.next_seq += 1;
        try self.events.append(a, .{
            .router_decision = .{
                .seq = seq,
                .pipeline = try a.dupe(u8, pipeline),
                .router = try a.dupe(u8, router),
                .target_pipeline = if (target_pipeline) |t| try a.dupe(u8, t) else null,
            },
        });
    }

    pub fn toJsonLines(self: *const ExecutionTracer, allocator: Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        for (self.events.items) |ev| {
            switch (ev) {
                .step_start => |s| {
                    try out.appendSlice(allocator, "{\"event\":\"step_start\",\"seq\":");
                    try appendUint(&out, allocator, s.seq);
                    try out.appendSlice(allocator, ",\"pipeline\":");
                    try appendJsonString(&out, allocator, s.pipeline);
                    try out.appendSlice(allocator, ",\"step\":");
                    try appendJsonString(&out, allocator, s.step);
                    try out.appendSlice(allocator, "}\n");
                },
                .task_log => |l| {
                    try out.appendSlice(allocator, "{\"event\":\"task_log\",\"seq\":");
                    try appendUint(&out, allocator, l.seq);
                    try out.appendSlice(allocator, ",\"pipeline\":");
                    try appendJsonString(&out, allocator, l.pipeline);
                    try out.appendSlice(allocator, ",\"step\":");
                    try appendJsonString(&out, allocator, l.step);
                    try out.appendSlice(allocator, ",\"level\":");
                    try appendJsonString(&out, allocator, @tagName(l.level));
                    try out.appendSlice(allocator, ",\"message\":");
                    try appendJsonString(&out, allocator, l.message);
                    try out.appendSlice(allocator, "}\n");
                },
                .step_end => |e| {
                    try out.appendSlice(allocator, "{\"event\":\"step_end\",\"seq\":");
                    try appendUint(&out, allocator, e.seq);
                    try out.appendSlice(allocator, ",\"pipeline\":");
                    try appendJsonString(&out, allocator, e.pipeline);
                    try out.appendSlice(allocator, ",\"step\":");
                    try appendJsonString(&out, allocator, e.step);
                    try out.appendSlice(allocator, ",\"status\":");
                    try appendJsonString(&out, allocator, @tagName(e.status));
                    try out.appendSlice(allocator, ",\"windows_read\":");
                    try appendUint(&out, allocator, e.windows_read);
                    try out.appendSlice(allocator, ",\"rows_read\":");
                    try appendUint(&out, allocator, e.rows_read);
                    try out.appendSlice(allocator, ",\"rows_emitted\":");
                    try appendUint(&out, allocator, e.rows_emitted);
                    try out.appendSlice(allocator, "}\n");
                },
                .router_decision => |r| {
                    try out.appendSlice(allocator, "{\"event\":\"router_decision\",\"seq\":");
                    try appendUint(&out, allocator, r.seq);
                    try out.appendSlice(allocator, ",\"pipeline\":");
                    try appendJsonString(&out, allocator, r.pipeline);
                    try out.appendSlice(allocator, ",\"router\":");
                    try appendJsonString(&out, allocator, r.router);
                    try out.appendSlice(allocator, ",\"goto\":");
                    if (r.target_pipeline) |t| {
                        try appendJsonString(&out, allocator, t);
                    } else {
                        try out.appendSlice(allocator, "null");
                    }
                    try out.appendSlice(allocator, "}\n");
                },
            }
        }

        return out.toOwnedSlice(allocator);
    }

    fn appendUint(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, v: usize) !void {
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
        try buf.appendSlice(allocator, s);
    }

    fn appendJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, s: []const u8) !void {
        try buf.append(allocator, '"');
        for (s) |ch| {
            switch (ch) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => try buf.append(allocator, ch),
            }
        }
        try buf.append(allocator, '"');
    }
};

/// Microkernel extension translating TelemetryBus events into structured `.jsonl` traces.
pub const JsonlTraceExtension = struct {
    allocator: Allocator,
    tracer: ExecutionTracer,
    output_path: ?[]const u8 = null,

    pub fn init(allocator: Allocator, output_path: ?[]const u8) JsonlTraceExtension {
        return .{
            .allocator = allocator,
            .tracer = ExecutionTracer.init(allocator),
            .output_path = output_path,
        };
    }

    pub fn deinit(self: *JsonlTraceExtension) void {
        self.tracer.deinit();
    }

    pub fn onEvent(self: *JsonlTraceExtension, event: *const TelemetryEvent) void {
        switch (event.*) {
            .step_start => |s| {
                _ = self.tracer.recordStepStart(s.pipeline_name, s.step_id) catch {};
            },
            .step_end => |e| {
                const status: TaskStatus_ABI = if (std.mem.eql(u8, e.status, "ok")) .ok else .fatal_error;
                self.tracer.recordStepEnd(
                    0,
                    e.pipeline_name,
                    e.step_id,
                    status,
                    0,
                    0,
                    0,
                ) catch {};
            },
            .router_decision => |r| {
                self.tracer.recordRouterDecision(
                    r.pipeline_name,
                    r.router_id,
                    r.target_pipeline,
                ) catch {};
            },
            else => {},
        }
    }

    pub fn flush(self: *JsonlTraceExtension, _: *flowdata.RepositoryRegistry) anyerror!void {
        if (self.output_path) |path| {
            const lines = try self.tracer.toJsonLines(self.allocator);
            defer self.allocator.free(lines);
            try flowdata.writeFileBytes(self.allocator, path, lines);
        }
    }

    pub fn subscriber(self: *JsonlTraceExtension) TelemetrySubscriber {
        const Trampoline = struct {
            fn doOnEvent(ctx: *anyopaque, event: *const TelemetryEvent) void {
                const s: *JsonlTraceExtension = @ptrCast(@alignCast(ctx));
                s.onEvent(event);
            }

            fn doFlush(ctx: *anyopaque, repos: *flowdata.RepositoryRegistry) anyerror!void {
                const s: *JsonlTraceExtension = @ptrCast(@alignCast(ctx));
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

    pub fn extension(self: *JsonlTraceExtension) Extension {
        const Trampoline = struct {
            fn register(ctx_ptr: *anyopaque, k: *KernelContext) anyerror!void {
                const s: *JsonlTraceExtension = @ptrCast(@alignCast(ctx_ptr));
                try k.telemetry.subscribe(s.subscriber());
            }

            fn deinitExt(ctx_ptr: *anyopaque, _: Allocator) void {
                const s: *JsonlTraceExtension = @ptrCast(@alignCast(ctx_ptr));
                s.deinit();
            }

            const vtable = Extension.VTable{
                .register = &register,
                .deinit = &deinitExt,
            };
        };
        return .{
            .name = "flowdata.trace_jsonl",
            .ptr = self,
            .vtable = &Trampoline.vtable,
        };
    }
};

pub const extension = Extension.fromStateless("flowdata.trace_jsonl", struct {
    var default_inst: ?JsonlTraceExtension = null;

    fn reg(k: *KernelContext) anyerror!void {
        if (default_inst == null) {
            default_inst = JsonlTraceExtension.init(k.allocator, null);
        }
        try k.telemetry.subscribe(default_inst.?.subscriber());
    }
}.reg);
