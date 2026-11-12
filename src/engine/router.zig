//! Flowdata Reactive Inbound/Outbound Type-Driven Router (ARCH-018).
//!
//! Evaluates service catalog predicates (`canHandle`), short-circuit unary input filters,
//! ambient context merging, intermediate sub-DAG re-entry, and outbound re-routing loops.

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
const task_executor = @import("../plugin/loader/task_executor.zig");
const RecordEmitter = @import("reactor.zig").RecordEmitter;
const AmbientContext = @import("ambient_context.zig").AmbientContext;

pub const RouteOptions = struct {
    max_re_route_depth: usize = 16,
    enable_outbound_loop: bool = true,
};

fn evaluateReflectedPredicate(val: dataflow.ReflectedValue, expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len == 0) return true;

    var op_idx: usize = 0;
    var op_len: usize = 0;
    var op: dataflow.predicate.ComparisonOp = .truthy;
    if (std.mem.indexOf(u8, trimmed, "==")) |idx| {
        op = .eq; op_idx = idx; op_len = 2;
    } else if (std.mem.indexOf(u8, trimmed, "!=")) |idx| {
        op = .ne; op_idx = idx; op_len = 2;
    } else if (std.mem.indexOf(u8, trimmed, ">=")) |idx| {
        op = .gte; op_idx = idx; op_len = 2;
    } else if (std.mem.indexOf(u8, trimmed, "<=")) |idx| {
        op = .lte; op_idx = idx; op_len = 2;
    } else if (std.mem.indexOf(u8, trimmed, ">")) |idx| {
        op = .gt; op_idx = idx; op_len = 1;
    } else if (std.mem.indexOf(u8, trimmed, "<")) |idx| {
        op = .lt; op_idx = idx; op_len = 1;
    }

    if (op == .truthy) {
        return val.isTruthy();
    }

    const rhs_raw = std.mem.trim(u8, trimmed[op_idx + op_len ..], " \t\r\n");
    const rhs_float = std.fmt.parseFloat(f64, rhs_raw) catch null;
    const lhs_float = val.asFloat();
    if (lhs_float != null and rhs_float != null) {
        return switch (op) {
            .eq => lhs_float.? == rhs_float.?,
            .ne => lhs_float.? != rhs_float.?,
            .gte => lhs_float.? >= rhs_float.?,
            .lte => lhs_float.? <= rhs_float.?,
            .gt => lhs_float.? > rhs_float.?,
            .lt => lhs_float.? < rhs_float.?,
            .truthy => true,
        };
    }
    return false;
}

/// Type-driven reactive router managing service catalog matching,
/// intermediate sub-DAG dispatch, and recursive output re-routing loops.
pub const ReactiveRouter = struct {
    allocator: Allocator,
    engine: *PipelineEngine,
    pipeline_name: []const u8,
    plan: ExecutionPlan,
    pool: ?*WorkerPool = null,
    owns_pool: bool = false,
    net_ctrl: *EngineNetworkController,
    outputs: std.StringHashMapUnmanaged(PayloadHandle) = .empty,
    outputs_arena: std.heap.ArenaAllocator,
    total_routed: usize = 0,
    total_re_routed: usize = 0,

    pub fn init(allocator: Allocator, engine: *PipelineEngine, pipeline_name: []const u8) !*ReactiveRouter {
        const pipe = engine.ast.getPipeline(pipeline_name) orelse return error.UnknownSubPipeline;
        var plan = try compilePlan(allocator, pipe, engine.ast);
        errdefer plan.deinit();

        const net_ctrl_ptr = try allocator.create(EngineNetworkController);
        errdefer allocator.destroy(net_ctrl_ptr);
        net_ctrl_ptr.* = try EngineNetworkController.init(allocator, engine.ast, engine.networks);
        errdefer net_ctrl_ptr.deinit();

        var pool_ptr: ?*WorkerPool = null;
        if (engine.workers > 1) {
            pool_ptr = try WorkerPool.init(allocator, engine.workers);
        }
        errdefer if (pool_ptr) |p| p.deinit();

        const self = try allocator.create(ReactiveRouter);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .engine = engine,
            .pipeline_name = pipeline_name,
            .plan = plan,
            .pool = pool_ptr,
            .owns_pool = (pool_ptr != null),
            .net_ctrl = net_ctrl_ptr,
            .outputs_arena = std.heap.ArenaAllocator.init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *ReactiveRouter) void {
        if (self.owns_pool) {
            if (self.pool) |p| p.deinit();
        }
        self.net_ctrl.deinit();
        self.allocator.destroy(self.net_ctrl);
        self.outputs_arena.deinit();
        self.plan.deinit();
        self.allocator.destroy(self);
    }

    pub fn emitter(self: *ReactiveRouter) RecordEmitter {
        const Trampoline = struct {
            fn emitFn(ctx: *anyopaque, source_id: []const u8, record: PayloadHandle) anyerror!void {
                _ = source_id;
                const r: *ReactiveRouter = @ptrCast(@alignCast(ctx));
                _ = try r.route(record, .{});
            }
        };
        return .{
            .ptr = self,
            .emit_fn = &Trampoline.emitFn,
        };
    }

    /// Finds all node IDs in the execution plan whose task service predicates (`canHandle`)
    /// and unary input filters are satisfied for `payload`.
    pub fn findMatchingNodes(self: *const ReactiveRouter, payload: PayloadHandle) ![]NodeId {
        var matches: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer matches.deinit(self.allocator);

        const abi_payload = task_executor.toAbiPayload(payload);

        for (self.plan.nodes, 0..) |node, node_id| {
            const task_spec = node.step.task;
            const desc = self.engine.modules.resolveTask(task_spec.module, task_spec.task) catch continue;

            // 1. Evaluate task service canHandle predicate (ARCH-018 §3.1)
            if (!desc.canHandle(&abi_payload)) {
                continue;
            }

            // 2. Evaluate unary where: filters on task inputs (ARCH-018 §3.3)
            var passes_unary = true;
            for (task_spec.inputs) |in_b| {
                if (in_b.where_filter) |wf| {
                    if (in_b.expr.stream_ref) |sref| {
                        // Check if from ambient stream (system.*, env.*)
                        if (std.mem.startsWith(u8, sref, "system.") or std.mem.startsWith(u8, sref, "env.")) {
                            if (self.engine.ambient.getReflected(sref)) |amb_val| {
                                if (!evaluateReflectedPredicate(amb_val, wf)) {
                                    passes_unary = false;
                                    break;
                                }
                            }
                        } else {
                            // Evaluate against incoming payload
                            if (!dataflow.predicate.evaluatePredicateHandle(payload, wf)) {
                                passes_unary = false;
                                break;
                            }
                        }
                    }
                }
            }

            if (passes_unary) {
                try matches.append(self.allocator, node_id);
            }
        }

        return matches.toOwnedSlice(self.allocator);
    }

    /// Routes an emitted payload into the pipeline, activating matched tasks and their
    /// downstream reachability sub-DAG.
    pub fn route(self: *ReactiveRouter, payload: PayloadHandle, opts: RouteOptions) anyerror!ExecutionSummary {
        const visited_mask = try self.allocator.alloc(bool, self.plan.nodes.len);
        defer self.allocator.free(visited_mask);
        @memset(visited_mask, false);
        return self.routeInternal(payload, opts, 0, visited_mask);
    }

    fn routeInternal(
        self: *ReactiveRouter,
        payload: PayloadHandle,
        opts: RouteOptions,
        depth: usize,
        visited_mask: []bool,
    ) anyerror!ExecutionSummary {
        if (depth > opts.max_re_route_depth) {
            return error.MaxReRouteDepthExceeded;
        }

        self.total_routed += 1;

        const matching_nodes = try self.findMatchingNodes(payload);
        defer self.allocator.free(matching_nodes);

        var fresh_matches: std.ArrayListUnmanaged(NodeId) = .empty;
        defer fresh_matches.deinit(self.allocator);
        for (matching_nodes) |m_id| {
            if (!visited_mask[m_id]) {
                try fresh_matches.append(self.allocator, m_id);
            }
        }

        if (fresh_matches.items.len == 0) {
            return ExecutionSummary{
                .steps_executed = 0,
                .routers_evaluated = 1,
                .halted_early = false,
                .final_pipeline = self.pipeline_name,
            };
        }

        // Compute reachability mask for downstream closure starting from matched nodes
        const nodes_count = self.plan.nodes.len;
        const active_mask = try self.allocator.alloc(bool, nodes_count);
        defer self.allocator.free(active_mask);
        @memset(active_mask, false);

        var queue: std.ArrayListUnmanaged(NodeId) = .empty;
        defer queue.deinit(self.allocator);

        for (fresh_matches.items) |m_id| {
            active_mask[m_id] = true;
            try queue.append(self.allocator, m_id);
        }

        const abi_payload = task_executor.toAbiPayload(payload);

        while (queue.items.len > 0) {
            const u = queue.orderedRemove(0);
            for (self.plan.nodes[u].successors) |v| {
                if (!active_mask[v]) {
                    if (opts.enable_outbound_loop) {
                        const v_task = self.plan.nodes[v].step.task;
                        if (self.engine.modules.resolveTask(v_task.module, v_task.task)) |v_desc| {
                            if (v_desc.can_handle != null and !v_desc.canHandle(&abi_payload)) {
                                continue;
                            }
                        } else |_| {}
                    }
                    active_mask[v] = true;
                    try queue.append(self.allocator, v);
                }
            }
        }

        const outputs_alloc = self.outputs_arena.allocator();
        var local_outputs: std.StringHashMapUnmanaged(PayloadHandle) = .empty;
        defer local_outputs.deinit(self.allocator);
        try local_outputs.put(outputs_alloc, "stream", payload);
        try local_outputs.put(outputs_alloc, "input", payload);

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

        var summary = ExecutionSummary{};

        // Execute selective sub-DAG via Coordinator
        if (self.pool != null and nodes_count > 1) {
            try Coordinator.runSelective(
                self.engine,
                &self.plan,
                active_mask,
                payload,
                &local_outputs,
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
                &local_outputs,
                outputs_alloc,
                self.net_ctrl,
                &summary,
                trace_id,
                root_span_id,
                self.pool,
            );
        }

        for (0..nodes_count) |i| {
            if (active_mask[i]) visited_mask[i] = true;
        }

        var copy_iter = local_outputs.iterator();
        while (copy_iter.next()) |entry| {
            try self.outputs.put(outputs_alloc, entry.key_ptr.*, entry.value_ptr.*);
        }

        // Outbound Re-routing Loop (ARCH-018 §2 & §4)
        if (opts.enable_outbound_loop and !summary.halted_early) {
            for (self.plan.nodes) |node| {
                if (!active_mask[node.id]) continue;
                const task_spec = node.step.task;
                if (task_spec.outputs.len > 0) {
                    for (task_spec.outputs) |out_ch| {
                        const out_payload = local_outputs.get(out_ch.name) orelse continue;
                        if (out_payload.len == 0) continue;

                        const next_matches = try self.findMatchingNodes(out_payload);
                        defer self.allocator.free(next_matches);

                        var has_fresh_target = false;
                        for (next_matches) |next_id| {
                            if (!visited_mask[next_id]) {
                                has_fresh_target = true;
                                break;
                            }
                        }

                        if (has_fresh_target) {
                            self.total_re_routed += 1;
                            const sub_summary = try self.routeInternal(out_payload, opts, depth + 1, visited_mask);
                            summary.steps_executed += sub_summary.steps_executed;
                            summary.routers_evaluated += sub_summary.routers_evaluated;
                        }
                    }
                } else if (local_outputs.get(task_spec.id)) |out_payload| {
                    if (out_payload.len > 0) {
                        const next_matches = try self.findMatchingNodes(out_payload);
                        defer self.allocator.free(next_matches);

                        var has_fresh_target = false;
                        for (next_matches) |next_id| {
                            if (!visited_mask[next_id]) {
                                has_fresh_target = true;
                                break;
                            }
                        }

                        if (has_fresh_target) {
                            self.total_re_routed += 1;
                            const sub_summary = try self.routeInternal(out_payload, opts, depth + 1, visited_mask);
                            summary.steps_executed += sub_summary.steps_executed;
                            summary.routers_evaluated += sub_summary.routers_evaluated;
                        }
                    }
                }
            }
        }

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
};
