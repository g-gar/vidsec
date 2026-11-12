//! Type-Driven / Service Catalog Routing Strategy (ARCH-023 Phase 4).
//!
//! Pure signature-driven router that evaluates `TaskDescriptor_ABI.canHandle`,
//! unary `where:` filters (including ambient `system.*` / `env.*` streams),
//! intermediate sub-DAG entry, and bounded outbound re-routing loops.
//!
//! Intentionally isolated from `WorkerPool`, `Coordinator`, and `NetworkController`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast/ast.zig");
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const modules_mod = @import("../../plugin/mod.zig");
const task_executor = @import("../../plugin/loader/task_executor.zig");
const AmbientContext = @import("../ambient_context.zig").AmbientContext;
const strategy_mod = @import("strategy.zig");

pub const NodeId = strategy_mod.NodeId;
pub const RoutingStrategy = strategy_mod.RoutingStrategy;
pub const RoutingContext = strategy_mod.RoutingContext;
pub const TaskActivation = strategy_mod.TaskActivation;
pub const StepOutcomeEvent = strategy_mod.StepOutcomeEvent;
pub const BoundInput = strategy_mod.BoundInput;

pub const TypeDrivenOptions = struct {
    max_re_route_depth: usize = 16,
    enable_outbound_loop: bool = true,
};

pub const TypeDrivenRouter = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    pipeline: ast.PipelineDecl,
    modules: *const modules_mod.ModuleRegistry,
    ambient: *const AmbientContext,
    options: TypeDrivenOptions,
    active_mask: ?[]const bool = null,

    visited_mask: []bool,
    pending_count: usize = 0,
    re_route_depth: usize = 0,
    halted: bool = false,

    pub fn init(ctx: RoutingContext, options: TypeDrivenOptions) !*TypeDrivenRouter {
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        errdefer arena.deinit();

        const visited = try ctx.allocator.alloc(bool, ctx.pipeline.steps.len);
        errdefer ctx.allocator.free(visited);
        @memset(visited, false);

        const self = try ctx.allocator.create(TypeDrivenRouter);
        self.* = .{
            .allocator = ctx.allocator,
            .arena = arena,
            .pipeline = ctx.pipeline,
            .modules = ctx.modules,
            .ambient = ctx.ambient,
            .options = options,
            .active_mask = ctx.active_mask,
            .visited_mask = visited,
        };
        return self;
    }

    pub fn deinit(self: *TypeDrivenRouter) void {
        self.allocator.free(self.visited_mask);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn strategy(self: *TypeDrivenRouter) RoutingStrategy {
        return RoutingStrategy.fromImpl(TypeDrivenRouter, self);
    }

    pub fn factory(ctx: RoutingContext) anyerror!RoutingStrategy {
        const impl = try TypeDrivenRouter.init(ctx, .{});
        return impl.strategy();
    }

    /// Returns all node IDs whose service `canHandle` and unary `where:` filters pass for `payload`.
    pub fn findMatchingNodes(self: *const TypeDrivenRouter, alloc: Allocator, payload: PayloadHandle) ![]NodeId {
        var matches: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer matches.deinit(alloc);

        const abi_payload = task_executor.toAbiPayload(payload);

        for (self.pipeline.steps, 0..) |step, node_id| {
            if (self.active_mask) |mask| {
                if (node_id < mask.len and !mask[node_id]) continue;
            }
            if (step != .task) continue;
            const task_spec = step.task;
            const desc = self.modules.resolveTask(task_spec.module, task_spec.task) catch continue;

            if (!desc.canHandle(&abi_payload)) continue;
            if (!self.passesUnaryFilters(task_spec, payload)) continue;

            try matches.append(alloc, node_id);
        }

        return matches.toOwnedSlice(alloc);
    }

    pub fn onPipelineStart(self: *TypeDrivenRouter, alloc: Allocator, initial_input: PayloadHandle) ![]TaskActivation {
        if (self.halted or self.pipeline.steps.len == 0) return &.{};
        return self.activateMatches(alloc, initial_input);
    }

    pub fn onStepComplete(self: *TypeDrivenRouter, alloc: Allocator, event: StepOutcomeEvent) ![]TaskActivation {
        if (self.pending_count > 0) self.pending_count -= 1;

        if (event.status == .fatal_error or event.status == .halt_pipeline) {
            self.halted = true;
            return &.{};
        }
        if (self.halted or !self.options.enable_outbound_loop) return &.{};
        if (self.re_route_depth >= self.options.max_re_route_depth) return &.{};

        var all_activations: std.ArrayListUnmanaged(TaskActivation) = .empty;
        errdefer all_activations.deinit(alloc);

        var routed_any = false;
        for (event.channel_outputs) |ch_out| {
            if (ch_out.payload.len == 0) continue;
            const acts = try self.activateMatches(alloc, ch_out.payload);
            if (acts.len > 0) {
                routed_any = true;
                try all_activations.appendSlice(alloc, acts);
            }
        }

        if (event.output.len > 0) {
            const acts = try self.activateMatches(alloc, event.output);
            if (acts.len > 0) {
                routed_any = true;
                try all_activations.appendSlice(alloc, acts);
            }
        }

        if (routed_any) {
            self.re_route_depth += 1;
        }

        return all_activations.toOwnedSlice(alloc);
    }

    pub fn hasPendingWork(self: *const TypeDrivenRouter) bool {
        return !self.halted and self.pending_count > 0;
    }

    fn activateMatches(self: *TypeDrivenRouter, alloc: Allocator, payload: PayloadHandle) ![]TaskActivation {
        const matches = try self.findMatchingNodes(alloc, payload);
        defer alloc.free(matches);

        var activations: std.ArrayListUnmanaged(TaskActivation) = .empty;
        errdefer activations.deinit(alloc);

        for (matches) |node_id| {
            if (self.visited_mask[node_id]) continue;
            self.visited_mask[node_id] = true;
            self.pending_count += 1;

            const bound = try self.buildBoundInputs(payload);
            try activations.append(alloc, .{
                .node_id = node_id,
                .step_input = payload,
                .bound_inputs = bound,
            });
        }

        return activations.toOwnedSlice(alloc);
    }

    fn buildBoundInputs(self: *TypeDrivenRouter, payload: PayloadHandle) ![]const BoundInput {
        const arena_alloc = self.arena.allocator();
        var bound: std.ArrayListUnmanaged(BoundInput) = .empty;

        try bound.append(arena_alloc, .{ .name = "stream", .payload = payload });
        try bound.append(arena_alloc, .{ .name = "input", .payload = payload });

        if (try self.ambient.asPayload(arena_alloc, "system.timestamp")) |ts_p| {
            try bound.append(arena_alloc, .{ .name = "system.timestamp", .payload = ts_p });
            try bound.append(arena_alloc, .{ .name = "timestamp", .payload = ts_p });
        }
        if (try self.ambient.asPayload(arena_alloc, "system.hour")) |hr_p| {
            try bound.append(arena_alloc, .{ .name = "system.hour", .payload = hr_p });
            try bound.append(arena_alloc, .{ .name = "hour", .payload = hr_p });
        }
        if (try self.ambient.asPayload(arena_alloc, "system.cpu_load")) |cpu_p| {
            try bound.append(arena_alloc, .{ .name = "system.cpu_load", .payload = cpu_p });
            try bound.append(arena_alloc, .{ .name = "cpu_load", .payload = cpu_p });
            try bound.append(arena_alloc, .{ .name = "cpu_usage", .payload = cpu_p });
        }

        return bound.toOwnedSlice(arena_alloc);
    }

    fn passesUnaryFilters(self: *const TypeDrivenRouter, task_spec: ast.TaskStepSpec, payload: PayloadHandle) bool {
        if (task_spec.where_filter) |wf| {
            if (!dataflow.predicate.evaluatePredicateHandle(payload, wf)) return false;
        }
        for (task_spec.inputs) |in_b| {
            if (in_b.where_filter) |wf| {
                if (in_b.expr.stream_ref) |sref| {
                    if (std.mem.startsWith(u8, sref, "system.") or std.mem.startsWith(u8, sref, "env.")) {
                        if (self.ambient.getReflected(sref)) |amb_val| {
                            if (!evaluateReflectedPredicate(amb_val, wf)) return false;
                        }
                    } else {
                        if (!dataflow.predicate.evaluatePredicateHandle(payload, wf)) return false;
                    }
                }
            }
        }
        return true;
    }
};

pub fn evaluateReflectedPredicate(val: dataflow.ReflectedValue, expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len == 0) return true;

    var op_idx: usize = 0;
    var op_len: usize = 0;
    var op: dataflow.predicate.ComparisonOp = .truthy;
    if (std.mem.indexOf(u8, trimmed, "==")) |idx| {
        op = .eq;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, trimmed, "!=")) |idx| {
        op = .ne;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, trimmed, ">=")) |idx| {
        op = .gte;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, trimmed, "<=")) |idx| {
        op = .lte;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, trimmed, ">")) |idx| {
        op = .gt;
        op_idx = idx;
        op_len = 1;
    } else if (std.mem.indexOf(u8, trimmed, "<")) |idx| {
        op = .lt;
        op_idx = idx;
        op_len = 1;
    }

    if (op == .truthy) return val.isTruthy();

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
