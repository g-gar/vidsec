//! Flowdata Reactive Push Reactor (ARCH-014 §2, §3.3 & §4).
//!
//! Manages the task subscription graph, decouples event production from storage repositories,
//! and dispatches emitted records to subscribed root tasks with zero-lock concurrent fan-out
//! across the shared WorkerPool.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast_mod = @import("../ast/ast.zig");
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const engine_mod = @import("engine.zig");
const PipelineEngine = engine_mod.PipelineEngine;
const ExecutionSummary = engine_mod.ExecutionSummary;
const Coordinator = @import("coordinator.zig").Coordinator;
const plan_mod = @import("plan.zig");
const ExecutionPlan = plan_mod.ExecutionPlan;
const NodeId = plan_mod.NodeId;
const compilePlan = plan_mod.compilePlan;
const WorkerPool = @import("../concurrency/mod.zig").WorkerPool;
const EngineNetworkController = @import("network.zig").EngineNetworkController;

/// Agnostic event emission interface for pushing items into the Flowdata engine.
/// Allows external collectors (ARCH-019), webhooks, test harnesses, or datasources
/// to inject payloads without coupling to the pipeline topology.
pub const RecordEmitter = struct {
    ptr: *anyopaque,
    emit_fn: *const fn (ctx: *anyopaque, source_id: []const u8, record: PayloadHandle) anyerror!void,

    pub fn emit(self: RecordEmitter, source_id: []const u8, record: PayloadHandle) !void {
        return self.emit_fn(self.ptr, source_id, record);
    }

    pub fn emitRecord(self: RecordEmitter, source_id: []const u8, record: anytype) !void {
        const T = @TypeOf(record);
        if (T == PayloadHandle) {
            return self.emit(source_id, record);
        } else if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice) {
            return self.emit(source_id, PayloadHandle.fromSlice(@typeInfo(T).pointer.child, record));
        } else {
            return self.emit(source_id, PayloadHandle.fromScalar(T, &record));
        }
    }
};

/// Core Reactive Push Reactor.
/// Owns the pipeline subscription index and coordinates reactive execution of sub-DAGs
/// when records are emitted.
pub const PushReactor = struct {
    allocator: Allocator,
    engine: *PipelineEngine,
    pipeline_name: []const u8,
    plan: ExecutionPlan,
    subscriptions: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(NodeId)) = .empty,
    default_subscribers: std.ArrayListUnmanaged(NodeId) = .empty,
    pool: ?*WorkerPool = null,
    owns_pool: bool = false,
    net_ctrl: *EngineNetworkController,
    owns_net_ctrl: bool = false,
    outputs: std.StringHashMapUnmanaged(PayloadHandle) = .empty,
    outputs_arena: std.heap.ArenaAllocator,
    total_emitted: usize = 0,
    total_dispatched: usize = 0,

    pub fn init(allocator: Allocator, engine: *PipelineEngine, pipeline_name: []const u8) !*PushReactor {
        const pipe = engine.ast.getPipeline(pipeline_name) orelse return error.UnknownSubPipeline;
        var plan = try compilePlan(allocator, pipe, engine.ast);
        errdefer plan.deinit();

        // 1. Resolve or instantiate all declared datasources in repository registry
        for (engine.ast.datasources) |ds_spec| {
            _ = try engine.repos.resolveOrCreate(ds_spec);
        }

        // 2. Initialize EngineNetworkController for reactive network steps
        const net_ctrl_ptr = try allocator.create(EngineNetworkController);
        errdefer allocator.destroy(net_ctrl_ptr);
        net_ctrl_ptr.* = try EngineNetworkController.init(allocator, engine.ast, engine.networks);
        errdefer net_ctrl_ptr.deinit();

        // 3. WorkerPool for multi-branch concurrent fan-out
        var pool_ptr: ?*WorkerPool = null;
        if (engine.workers > 1) {
            pool_ptr = try WorkerPool.init(allocator, engine.workers);
        }
        errdefer if (pool_ptr) |p| p.deinit();

        const self = try allocator.create(PushReactor);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .engine = engine,
            .pipeline_name = pipeline_name,
            .plan = plan,
            .subscriptions = .empty,
            .default_subscribers = .empty,
            .pool = pool_ptr,
            .owns_pool = (pool_ptr != null),
            .net_ctrl = net_ctrl_ptr,
            .owns_net_ctrl = true,
            .outputs = .empty,
            .outputs_arena = std.heap.ArenaAllocator.init(allocator),
            .total_emitted = 0,
            .total_dispatched = 0,
        };

        try self.indexSubscriptions();
        return self;
    }

    pub fn deinit(self: *PushReactor) void {
        var sub_it = self.subscriptions.iterator();
        while (sub_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.subscriptions.deinit(self.allocator);
        self.default_subscribers.deinit(self.allocator);

        self.outputs.deinit(self.outputs_arena.allocator());
        self.outputs_arena.deinit();

        if (self.owns_pool and self.pool != null) {
            self.pool.?.deinit();
        }
        if (self.owns_net_ctrl) {
            self.net_ctrl.deinit();
            self.allocator.destroy(self.net_ctrl);
        }
        self.plan.deinit();
        self.allocator.destroy(self);
    }

    fn isKnownDatasource(self: *const PushReactor, sref: []const u8) bool {
        for (self.engine.ast.datasources) |ds| {
            if (std.mem.eql(u8, ds.id, sref)) return true;
        }
        return false;
    }

    fn addSubscription(self: *PushReactor, source_id: []const u8, node_id: NodeId) !void {
        const entry = try self.subscriptions.getOrPut(self.allocator, source_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        for (entry.value_ptr.items) |existing| {
            if (existing == node_id) return;
        }
        try entry.value_ptr.append(self.allocator, node_id);
    }

    fn indexSubscriptions(self: *PushReactor) !void {
        for (self.plan.nodes, 0..) |node, node_id| {
            if (node.step != .task) continue;
            const task = node.step.task;
            if (task.inputs.len == 0) {
                try self.default_subscribers.append(self.allocator, node_id);
                try self.addSubscription("default", node_id);
                try self.addSubscription("stream", node_id);
                try self.addSubscription("input", node_id);
                try self.addSubscription("", node_id);
            } else {
                var bound_any_datasource = false;
                for (task.inputs) |in_bind| {
                    if (in_bind.expr.op == .none) {
                        if (in_bind.expr.stream_ref) |sref| {
                            if (std.mem.eql(u8, sref, "stream") or std.mem.eql(u8, sref, "input") or std.mem.eql(u8, sref, "file")) {
                                try self.default_subscribers.append(self.allocator, node_id);
                                try self.addSubscription("stream", node_id);
                                try self.addSubscription("input", node_id);
                                try self.addSubscription("", node_id);
                                bound_any_datasource = true;
                            } else if (self.isKnownDatasource(sref) or std.mem.eql(u8, sref, "jobs")) {
                                try self.addSubscription(sref, node_id);
                                bound_any_datasource = true;
                            }
                        }
                    }
                }
                if (!bound_any_datasource and node.indegree == 0) {
                    try self.default_subscribers.append(self.allocator, node_id);
                }
            }
        }
    }

    /// Returns a lightweight `RecordEmitter` handle referencing this reactor instance.
    pub fn emitter(self: *PushReactor) RecordEmitter {
        const Trampoline = struct {
            fn emitFn(ctx: *anyopaque, source_id: []const u8, record: PayloadHandle) anyerror!void {
                const r: *PushReactor = @ptrCast(@alignCast(ctx));
                _ = try r.emit(source_id, record);
            }
        };
        return .{
            .ptr = self,
            .emit_fn = &Trampoline.emitFn,
        };
    }

    /// Queries the registered root subscriber node IDs for a given source identifier.
    pub fn getSubscribers(self: *const PushReactor, source_id: []const u8) []const NodeId {
        if (self.subscriptions.get(source_id)) |list| {
            if (list.items.len > 0) return list.items;
        }
        if (source_id.len == 0 or std.mem.eql(u8, source_id, "stream") or std.mem.eql(u8, source_id, "input") or std.mem.eql(u8, source_id, "default")) {
            return self.default_subscribers.items;
        }
        return &.{};
    }

    pub fn hasSubscribers(self: *const PushReactor, source_id: []const u8) bool {
        return self.getSubscribers(source_id).len > 0;
    }

    /// Dispatches an emitted payload into the engine, executing the subscribed root tasks
    /// and their downstream DAG dependents concurrently across the shared WorkerPool.
    pub fn emit(self: *PushReactor, source_id: []const u8, payload: PayloadHandle) anyerror!ExecutionSummary {
        self.total_emitted += 1;

        // 1. Resolve matching root subscribers
        const matching_roots = self.getSubscribers(source_id);
        if (matching_roots.len == 0) {
            return ExecutionSummary{
                .steps_executed = 0,
                .routers_evaluated = 0,
                .halted_early = false,
                .final_pipeline = self.pipeline_name,
            };
        }

        // 2. Compute reachability mask for downstream DAG closure
        const nodes_count = self.plan.nodes.len;
        const active_mask = try self.allocator.alloc(bool, nodes_count);
        defer self.allocator.free(active_mask);
        @memset(active_mask, false);

        var queue: std.ArrayListUnmanaged(NodeId) = .empty;
        defer queue.deinit(self.allocator);

        for (matching_roots) |root_id| {
            active_mask[root_id] = true;
            try queue.append(self.allocator, root_id);
        }

        while (queue.items.len > 0) {
            const u = queue.orderedRemove(0);
            for (self.plan.nodes[u].successors) |v| {
                if (!active_mask[v]) {
                    active_mask[v] = true;
                    try queue.append(self.allocator, v);
                }
            }
        }

        // 3. Initialize trace telemetry
        const start_ns: u64 = engine_mod.nowNs();
        var trace_id: [16]u8 = undefined;
        var root_span_id: [8]u8 = undefined;
        engine_mod.fillRandomBytes(&trace_id);
        engine_mod.fillRandomBytes(&root_span_id);

        if (self.engine.kernel) |k| {
            k.telemetry.emit(.{
                .pipeline_start = .{
                    .trace_id = trace_id,
                    .span_id = root_span_id,
                    .timestamp_ns = start_ns,
                    .ast = &self.engine.ast,
                    .input_bytes_len = payload.len * payload.element_size,
                },
            });
        }

        // 4. Bind emitted payload into outputs so resolveStreamExpr finds it by source_id
        const outputs_alloc = self.outputs_arena.allocator();
        if (source_id.len > 0) {
            try self.outputs.put(outputs_alloc, source_id, payload);
        }
        try self.outputs.put(outputs_alloc, "stream", payload);
        try self.outputs.put(outputs_alloc, "input", payload);

        var summary = ExecutionSummary{};

        // 5. Execute via Coordinator (DAG mode with concurrent fan-out) or selective sub-pipeline
        if (self.engine.ast.runtime.scheduler == .dag and self.pool != null and nodes_count > 1) {
            try Coordinator.runSelective(
                self.engine,
                &self.plan,
                active_mask,
                payload,
                &self.outputs,
                outputs_alloc,
                self.net_ctrl,
                &summary,
                trace_id,
                root_span_id,
                self.pool.?,
            );
        } else {
            try self.engine.executeSubPipelineSelective(
                self.pipeline_name,
                active_mask,
                payload,
                &self.outputs,
                outputs_alloc,
                self.net_ctrl,
                &summary,
                trace_id,
                root_span_id,
                self.pool,
            );
        }

        self.total_dispatched += summary.steps_executed;

        if (self.engine.kernel) |k| {
            const end_ns: u64 = engine_mod.nowNs();
            k.telemetry.emit(.{
                .pipeline_end = .{
                    .trace_id = trace_id,
                    .span_id = root_span_id,
                    .timestamp_ns = end_ns,
                    .duration_ns = end_ns - start_ns,
                    .steps_executed = summary.steps_executed,
                    .routers_evaluated = summary.routers_evaluated,
                    .halted_early = summary.halted_early,
                    .final_pipeline = summary.final_pipeline,
                },
            });
        }

        return summary;
    }

    /// Convenience wrapper to emit any native Zig struct, slice, or DynamicRecord.
    pub fn emitRecord(self: *PushReactor, source_id: []const u8, record: anytype) anyerror!ExecutionSummary {
        const T = @TypeOf(record);
        if (T == PayloadHandle) {
            return self.emit(source_id, record);
        } else if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice) {
            return self.emit(source_id, PayloadHandle.fromSlice(@typeInfo(T).pointer.child, record));
        } else {
            return self.emit(source_id, PayloadHandle.fromScalar(T, &record));
        }
    }
};
