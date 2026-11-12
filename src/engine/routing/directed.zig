//! Directed / Nominal DAG Routing Strategy (ARCH-023 Phase 3).
//!
//! Pure graph-driven router that compiles an `ExecutionPlan` and tracks
//! in-degree readiness, nominal channel publication (`outputs:` -> `inputs:`),
//! stream algebra (`slice`, `merge`, `zip`, `join`), unary `where:` filters,
//! and innate ambient context merging (`system.*`).
//!
//! Intentionally isolated from `WorkerPool`, `Coordinator`, and `NetworkController`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast/ast.zig");
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const modules_mod = @import("../../plugin/mod.zig");
const repository = @import("../../repository/mod.zig");
const AmbientContext = @import("../ambient_context.zig").AmbientContext;
const plan_mod = @import("../plan.zig");
const strategy_mod = @import("strategy.zig");

pub const ExecutionPlan = plan_mod.ExecutionPlan;
pub const NodeId = plan_mod.NodeId;
pub const ChannelId = plan_mod.ChannelId;
pub const RoutingStrategy = strategy_mod.RoutingStrategy;
pub const RoutingContext = strategy_mod.RoutingContext;
pub const TaskActivation = strategy_mod.TaskActivation;
pub const StepOutcomeEvent = strategy_mod.StepOutcomeEvent;
pub const BoundInput = strategy_mod.BoundInput;

pub const DirectedRouter = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    ast_spec: ast.PipelineAST,
    plan: ExecutionPlan,
    ambient: *const AmbientContext,
    repos: ?*const repository.RepositoryRegistry,

    current_input: PayloadHandle = PayloadHandle.empty(),
    outputs: std.StringHashMapUnmanaged(PayloadHandle) = .empty,
    remaining_indegree: []usize,
    activated: []bool,
    pending_count: usize = 0,
    halted: bool = false,

    pub fn init(ctx: RoutingContext) !*DirectedRouter {
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        errdefer arena.deinit();

        var exec_plan = try plan_mod.compilePlan(ctx.allocator, ctx.pipeline, ctx.ast);
        errdefer exec_plan.deinit();

        const n = exec_plan.nodes.len;
        const indegrees = try ctx.allocator.alloc(usize, n);
        errdefer ctx.allocator.free(indegrees);
        const activated = try ctx.allocator.alloc(bool, n);
        errdefer ctx.allocator.free(activated);

        for (exec_plan.nodes, 0..) |node, i| {
            indegrees[i] = node.indegree;
            activated[i] = false;
        }

        const self = try ctx.allocator.create(DirectedRouter);
        self.* = .{
            .allocator = ctx.allocator,
            .arena = arena,
            .ast_spec = ctx.ast,
            .plan = exec_plan,
            .ambient = ctx.ambient,
            .repos = ctx.repos,
            .remaining_indegree = indegrees,
            .activated = activated,
        };
        return self;
    }

    pub fn deinit(self: *DirectedRouter) void {
        self.allocator.free(self.remaining_indegree);
        self.allocator.free(self.activated);
        self.plan.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn strategy(self: *DirectedRouter) RoutingStrategy {
        return RoutingStrategy.fromImpl(DirectedRouter, self);
    }

    pub fn factory(ctx: RoutingContext) anyerror!RoutingStrategy {
        const impl = try DirectedRouter.init(ctx);
        return impl.strategy();
    }

    pub fn onPipelineStart(self: *DirectedRouter, alloc: Allocator, initial_input: PayloadHandle) ![]TaskActivation {
        self.current_input = initial_input;
        if (self.plan.nodes.len == 0 or self.halted) return &.{};

        var ready: std.ArrayListUnmanaged(NodeId) = .empty;
        defer ready.deinit(alloc);

        for (self.plan.nodes, 0..) |_, i| {
            if (self.remaining_indegree[i] == 0 and !self.activated[i]) {
                try ready.append(alloc, i);
            }
        }

        return self.activateReadyQueue(alloc, &ready);
    }

    pub fn onStepComplete(self: *DirectedRouter, alloc: Allocator, event: StepOutcomeEvent) ![]TaskActivation {
        if (self.pending_count > 0) self.pending_count -= 1;

        if (event.status == .fatal_error or event.status == .halt_pipeline) {
            self.halted = true;
            return &.{};
        }
        if (self.halted or event.node_id >= self.plan.nodes.len) return &.{};

        try self.publishNodeOutputs(event.node_id, event.output, event.channel_outputs);

        var ready: std.ArrayListUnmanaged(NodeId) = .empty;
        defer ready.deinit(alloc);

        for (self.plan.nodes[event.node_id].successors) |succ_id| {
            if (self.remaining_indegree[succ_id] > 0) {
                self.remaining_indegree[succ_id] -= 1;
            }
            if (self.remaining_indegree[succ_id] == 0 and !self.activated[succ_id]) {
                try ready.append(alloc, succ_id);
            }
        }

        return self.activateReadyQueue(alloc, &ready);
    }

    pub fn hasPendingWork(self: *const DirectedRouter) bool {
        return !self.halted and self.pending_count > 0;
    }

    fn publishNodeOutputs(
        self: *DirectedRouter,
        node_id: NodeId,
        output: PayloadHandle,
        channel_outputs: []const strategy_mod.NamedPayload,
    ) !void {
        const arena_alloc = self.arena.allocator();
        const node = self.plan.nodes[node_id];
        if (node.step != .task) return;
        const task_spec = node.step.task;

        for (task_spec.outputs) |out_ch| {
            const ch_payload = findNamedPayload(channel_outputs, out_ch.name) orelse output;
            try self.outputs.put(arena_alloc, out_ch.name, ch_payload);
            const scoped = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ task_spec.id, out_ch.name });
            try self.outputs.put(arena_alloc, scoped, ch_payload);
        }

        if (task_spec.outputs.len == 0) {
            try self.outputs.put(arena_alloc, task_spec.id, output);
        }
    }

    fn activateReadyQueue(self: *DirectedRouter, alloc: Allocator, ready: *std.ArrayListUnmanaged(NodeId)) ![]TaskActivation {
        var activations: std.ArrayListUnmanaged(TaskActivation) = .empty;
        errdefer activations.deinit(alloc);

        while (ready.items.len > 0) {
            const node_id = ready.orderedRemove(0);
            if (self.activated[node_id]) continue;
            self.activated[node_id] = true;

            const node = self.plan.nodes[node_id];
            if (node.step != .task) {
                // Skip non-task nodes cleanly in pure graph traversal
                try self.unlockSuccessors(alloc, node_id, ready);
                continue;
            }

            if (try self.buildTaskActivation(node_id)) |act| {
                self.pending_count += 1;
                try activations.append(alloc, act);
            } else {
                // Short-circuited by unary `where:` filter: publish empty output and unlock successors
                try self.publishNodeOutputs(node_id, PayloadHandle.empty(), &.{});
                try self.unlockSuccessors(alloc, node_id, ready);
            }
        }

        return activations.toOwnedSlice(alloc);
    }

    fn unlockSuccessors(self: *DirectedRouter, alloc: Allocator, node_id: NodeId, ready: *std.ArrayListUnmanaged(NodeId)) !void {
        for (self.plan.nodes[node_id].successors) |succ_id| {
            if (self.remaining_indegree[succ_id] > 0) {
                self.remaining_indegree[succ_id] -= 1;
            }
            if (self.remaining_indegree[succ_id] == 0 and !self.activated[succ_id]) {
                try ready.append(alloc, succ_id);
            }
        }
    }

    fn buildTaskActivation(self: *DirectedRouter, node_id: NodeId) !?TaskActivation {
        const arena_alloc = self.arena.allocator();
        const node = self.plan.nodes[node_id];
        const task_spec = node.step.task;

        var step_input = self.current_input;
        var bound_inputs: std.ArrayListUnmanaged(BoundInput) = .empty;

        if (task_spec.inputs.len > 0) {
            for (task_spec.inputs) |in_binding| {
                var resolved = try self.resolveStreamExpr(in_binding.expr, self.current_input);
                if (in_binding.where_filter) |wf| {
                    resolved = try dataflow.predicate.filterPayload(arena_alloc, resolved, wf);
                    if (resolved.len == 0) {
                        return null;
                    }
                }
                try bound_inputs.append(arena_alloc, .{
                    .name = in_binding.param_name,
                    .payload = resolved,
                });
                if (std.mem.eql(u8, in_binding.param_name, "primary") or std.mem.eql(u8, in_binding.param_name, "stream")) {
                    step_input = resolved;
                }
            }
        }

        try bound_inputs.append(arena_alloc, .{
            .name = "stream",
            .payload = self.current_input,
        });
        try bound_inputs.append(arena_alloc, .{
            .name = "input",
            .payload = self.current_input,
        });

        // Innate ambient merge (ARCH-018 §3.2)
        if (try self.ambient.asPayload(arena_alloc, "system.timestamp")) |ts_p| {
            try bound_inputs.append(arena_alloc, .{ .name = "system.timestamp", .payload = ts_p });
            try bound_inputs.append(arena_alloc, .{ .name = "timestamp", .payload = ts_p });
        }
        if (try self.ambient.asPayload(arena_alloc, "system.hour")) |hr_p| {
            try bound_inputs.append(arena_alloc, .{ .name = "system.hour", .payload = hr_p });
            try bound_inputs.append(arena_alloc, .{ .name = "hour", .payload = hr_p });
        }
        if (try self.ambient.asPayload(arena_alloc, "system.cpu_load")) |cpu_p| {
            try bound_inputs.append(arena_alloc, .{ .name = "system.cpu_load", .payload = cpu_p });
            try bound_inputs.append(arena_alloc, .{ .name = "cpu_load", .payload = cpu_p });
            try bound_inputs.append(arena_alloc, .{ .name = "cpu_usage", .payload = cpu_p });
        }

        return TaskActivation{
            .node_id = node_id,
            .step_input = step_input,
            .bound_inputs = try bound_inputs.toOwnedSlice(arena_alloc),
            .consumed_channels = node.consumed_channels,
        };
    }

    pub fn resolveStreamExpr(
        self: *DirectedRouter,
        expr: ast.InboundStreamExpr,
        active_input: PayloadHandle,
    ) anyerror!PayloadHandle {
        const arena_alloc = self.arena.allocator();
        switch (expr.op) {
            .none => {
                if (expr.stream_ref) |ref| {
                    if (std.mem.eql(u8, ref, "stream") or std.mem.eql(u8, ref, "file")) {
                        return active_input;
                    }
                    if (std.mem.eql(u8, ref, "jobs")) {
                        if (self.ast_spec.jobs.len > 0) {
                            return PayloadHandle.fromSlice(ast.JobSpec, self.ast_spec.jobs);
                        }
                    }

                    if (std.mem.startsWith(u8, ref, "system.") or std.mem.startsWith(u8, ref, "env.")) {
                        if (try self.ambient.asPayload(arena_alloc, ref)) |amb_payload| {
                            return amb_payload;
                        }
                    }

                    if (self.outputs.get(ref)) |prev_out| {
                        return prev_out;
                    }
                    if (self.repos) |repos| {
                        if (repos.get(ref)) |repo| {
                            if (repo.readPayload(ref)) |payload| {
                                return payload;
                            }
                        }
                    }

                    if (std.mem.indexOfScalar(u8, ref, '.')) |dot_idx| {
                        const target_name = ref[0..dot_idx];
                        const field_name = ref[dot_idx + 1 ..];

                        const base_payload: ?PayloadHandle = if (self.outputs.get(target_name)) |bo|
                            bo
                        else if (self.repos) |repos|
                            if (repos.get(target_name)) |repo| repo.readPayload(target_name) else null
                        else
                            null;

                        if (base_payload) |bp| {
                            if (bp.getReflected(field_name)) |rval| {
                                const dyn_fields = try arena_alloc.alloc(dataflow.DynamicField, 1);
                                dyn_fields[0] = .{
                                    .name = try arena_alloc.dupe(u8, field_name),
                                    .value = rval,
                                };
                                const dyn_record = try arena_alloc.alloc(dataflow.DynamicRecord, 1);
                                dyn_record[0] = dataflow.DynamicRecord.init(dyn_fields);
                                return PayloadHandle.fromSlice(dataflow.DynamicRecord, dyn_record);
                            }
                        }
                    }
                }
                return active_input;
            },
            .slice => {
                var target = active_input;
                if (expr.sub_streams.len > 0) {
                    target = try self.resolveStreamExpr(expr.sub_streams[0], active_input);
                }
                return dataflow.algebra.slicePayload(target, expr.slice_offset, expr.slice_count);
            },
            .merge => {
                if (expr.sub_streams.len == 0) return active_input;
                var sub_payloads = try arena_alloc.alloc(PayloadHandle, expr.sub_streams.len);
                for (expr.sub_streams, 0..) |sub_expr, i| {
                    sub_payloads[i] = try self.resolveStreamExpr(sub_expr, active_input);
                }
                return try dataflow.algebra.mergePayloads(arena_alloc, sub_payloads);
            },
            .zip, .join => {
                if (expr.sub_streams.len > 0) {
                    return try self.resolveStreamExpr(expr.sub_streams[0], active_input);
                }
                return active_input;
            },
        }
    }
};

fn findNamedPayload(items: []const strategy_mod.NamedPayload, name: []const u8) ?PayloadHandle {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return item.payload;
    }
    return null;
}
