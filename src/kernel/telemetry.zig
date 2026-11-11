const std = @import("std");
const Allocator = std.mem.Allocator;
const ast_mod = @import("../ast/ast.zig");
const outbound_mod = @import("../transport/outbound/mod.zig");
const repository_mod = @import("../repository/mod.zig");
const Mutex = @import("../concurrency/mod.zig").Mutex;

pub const RepositoryRegistry = repository_mod.RepositoryRegistry;
pub const TraceId = [16]u8;
pub const SpanId = [8]u8;

pub const PacketDirection = enum(u8) {
    tx,
    rx,
};

pub const TelemetryEvent = union(enum) {
    pipeline_start: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        ast: *const ast_mod.PipelineAST,
        input_bytes_len: usize,
    },
    pipeline_end: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        duration_ns: u64,
        steps_executed: usize,
        routers_evaluated: usize,
        halted_early: bool,
        final_pipeline: []const u8,
    },
    step_start: struct {
        trace_id: TraceId,
        span_id: SpanId,
        parent_span_id: SpanId,
        timestamp_ns: u64,
        pipeline_name: []const u8,
        step_id: []const u8,
        module_name: []const u8,
        task_name: []const u8,
        input_count: usize,
    },
    step_end: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        duration_ns: u64,
        pipeline_name: []const u8,
        step_id: []const u8,
        status: []const u8,
        output_count: usize,
    },
    filter_evaluated: struct {
        trace_id: TraceId,
        span_id: SpanId,
        step_id: []const u8,
        expression: []const u8,
        items_in: usize,
        items_out: usize,
    },
    router_decision: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        pipeline_name: []const u8,
        router_id: []const u8,
        matched_expression: ?[]const u8,
        target_pipeline: ?[]const u8,
    },
    task_log: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        step_id: []const u8,
        level: u32,
        message: []const u8,
    },
    outbound_exchange: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        step_id: []const u8,
        adapter_id: []const u8,
        record: outbound_mod.CapturedExchangeRecord,
    },
    outbound_wire_packet: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        step_id: []const u8,
        adapter_id: []const u8,
        direction: PacketDirection,
        src_ip: [4]u8,
        dst_ip: [4]u8,
        src_port: u16,
        dst_port: u16,
        payload: []const u8,
        comment: []const u8,
        include_tls_keys: bool,
        snaplen: u32,
    },
};

pub const TelemetrySubscriber = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onEvent: *const fn (ctx: *anyopaque, event: *const TelemetryEvent) void,
        flush: ?*const fn (ctx: *anyopaque, repos: *RepositoryRegistry) anyerror!void = null,
        deinit: ?*const fn (ctx: *anyopaque, allocator: Allocator) void = null,
    };

    pub fn onEvent(self: TelemetrySubscriber, event: *const TelemetryEvent) void {
        self.vtable.onEvent(self.ptr, event);
    }

    pub fn flush(self: TelemetrySubscriber, repos: *RepositoryRegistry) anyerror!void {
        if (self.vtable.flush) |f| {
            try f(self.ptr, repos);
        }
    }

    pub fn deinit(self: TelemetrySubscriber, allocator: Allocator) void {
        if (self.vtable.deinit) |d| {
            d(self.ptr, allocator);
        }
    }
};

/// High-throughput event broadcast bus for execution lifecycle, distributed tracing, and wire tap.
/// Zero overhead on the critical path if `subscribers.items.len == 0`.
pub const TelemetryBus = struct {
    allocator: Allocator,
    subscribers: std.ArrayListUnmanaged(TelemetrySubscriber) = .empty,
    mutex: Mutex = .{},

    pub fn init(allocator: Allocator) TelemetryBus {
        return .{
            .allocator = allocator,
            .subscribers = .empty,
        };
    }

    pub fn deinit(self: *TelemetryBus) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscribers.items) |s| {
            s.deinit(self.allocator);
        }
        self.subscribers.deinit(self.allocator);
    }

    pub inline fn hasSubscribers(self: *const TelemetryBus) bool {
        return self.subscribers.items.len > 0;
    }

    pub fn subscribe(self: *TelemetryBus, sub: TelemetrySubscriber) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.subscribers.append(self.allocator, sub);
    }

    /// Emits a telemetry event to all registered subscribers.
    /// Inlined zero-cost branch if no subscribers are attached.
    pub inline fn emit(self: *TelemetryBus, event: TelemetryEvent) void {
        if (!self.hasSubscribers()) return;
        self.emitSlow(&event);
    }

    fn emitSlow(self: *TelemetryBus, event: *const TelemetryEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscribers.items) |s| {
            s.onEvent(event);
        }
    }

    pub fn flushAll(self: *TelemetryBus, repos: *RepositoryRegistry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscribers.items) |s| {
            try s.flush(repos);
        }
    }
};
