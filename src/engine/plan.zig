//! Flowdata Execution Plan Compiler (ARCH-017 §3.1).
//!
//! Compiles a pipeline AST into a validated Directed Acyclic Graph (DAG) with:
//! - Single-writer channel validation
//! - Data dependency resolution (`inputs:` -> producing step)
//! - Explicit ordering resolution (`after: [step_id, ...]`)
//! - Write serialization for shared non-memory datasources
//! - Router barrier dependencies
//! - Implicit sequential chaining for un-inputted steps
//! - Load-time cycle detection and topological sorting via Kahn's algorithm.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/ast.zig");

pub const NodeId = usize;
pub const ChannelId = usize;

pub const EdgeKind = enum {
    data,
    implicit_chain,
    ordering,
    router_barrier,

    pub fn priority(self: EdgeKind) u8 {
        return switch (self) {
            .data => 4,
            .ordering => 3,
            .router_barrier => 2,
            .implicit_chain => 1,
        };
    }
};

pub const PlanEdge = struct {
    from: NodeId,
    to: NodeId,
    kind: EdgeKind,
};

pub const ChannelSlot = struct {
    id: ChannelId,
    name: []const u8,
    producer_node: NodeId,
    consumers_count: usize = 0,
};

pub const PlanNode = struct {
    id: NodeId,
    step: ast.StepNode,
    indegree: usize = 0,
    successors: []const NodeId = &.{},
    predecessors: []const NodeId = &.{},
    produced_channels: []const ChannelId = &.{},
    consumed_channels: []const ChannelId = &.{},

    pub fn isTask(self: PlanNode) bool {
        return self.step == .task;
    }

    pub fn isRouter(self: PlanNode) bool {
        return self.step == .router;
    }

    pub fn stepId(self: PlanNode) []const u8 {
        return self.step.id();
    }
};

pub const PlanCompilerError = error{
    DuplicateStepId,
    SingleWriterViolation,
    UnknownStepDependency,
    UnknownChannelReference,
    CycleDetected,
    OutOfMemory,
};

pub const ExecutionPlan = struct {
    allocator: Allocator,
    pipeline_name: []const u8,
    nodes: []const PlanNode,
    edges: []const PlanEdge,
    channels: []const ChannelSlot,
    topological_order: []const NodeId,

    pub fn deinit(self: *ExecutionPlan) void {
        for (self.nodes) |node| {
            if (node.successors.len > 0) self.allocator.free(node.successors);
            if (node.predecessors.len > 0) self.allocator.free(node.predecessors);
            if (node.produced_channels.len > 0) self.allocator.free(node.produced_channels);
            if (node.consumed_channels.len > 0) self.allocator.free(node.consumed_channels);
        }
        if (self.nodes.len > 0) self.allocator.free(self.nodes);
        if (self.edges.len > 0) self.allocator.free(self.edges);
        if (self.channels.len > 0) self.allocator.free(self.channels);
        if (self.topological_order.len > 0) self.allocator.free(self.topological_order);
    }

    pub fn getNode(self: ExecutionPlan, id: NodeId) ?PlanNode {
        if (id < self.nodes.len) return self.nodes[id];
        return null;
    }

    pub fn findNodeByStepId(self: ExecutionPlan, step_id: []const u8) ?NodeId {
        for (self.nodes, 0..) |node, i| {
            if (std.mem.eql(u8, node.stepId(), step_id)) return i;
        }
        return null;
    }
};

fn isMemoryDatasource(ds_name: []const u8, ast_spec: ast.PipelineAST) bool {
    if (std.mem.eql(u8, ds_name, "pipeline_memory") or
        std.mem.eql(u8, ds_name, "memory") or
        std.mem.eql(u8, ds_name, "default"))
    {
        return true;
    }
    for (ast_spec.datasources) |ds| {
        if (std.mem.eql(u8, ds.id, ds_name)) {
            return std.mem.eql(u8, ds.driver, "memory");
        }
    }
    return false;
}

pub fn compilePlan(
    allocator: Allocator,
    pipeline: ast.PipelineDecl,
    ast_spec: ast.PipelineAST,
) PlanCompilerError!ExecutionPlan {
    const nodes_count = pipeline.steps.len;
    if (nodes_count == 0) {
        return ExecutionPlan{
            .allocator = allocator,
            .pipeline_name = pipeline.name,
            .nodes = &.{},
            .edges = &.{},
            .channels = &.{},
            .topological_order = &.{},
        };
    }

    // 1. Index step IDs and detect duplicate IDs
    var step_id_map: std.StringHashMapUnmanaged(NodeId) = .empty;
    defer step_id_map.deinit(allocator);

    for (pipeline.steps, 0..) |step, idx| {
        const sid = step.id();
        if (step_id_map.contains(sid)) {
            return error.DuplicateStepId;
        }
        try step_id_map.put(allocator, sid, idx);
    }

    // 2. Build Single-Writer Channel table and track node produced channels
    var channel_map: std.StringHashMapUnmanaged(ChannelId) = .empty;
    defer channel_map.deinit(allocator);

    var channels_list: std.ArrayListUnmanaged(ChannelSlot) = .empty;
    defer channels_list.deinit(allocator);

    var node_produced_channels = try allocator.alloc(std.ArrayListUnmanaged(ChannelId), nodes_count);
    defer {
        for (node_produced_channels) |*list| list.deinit(allocator);
        allocator.free(node_produced_channels);
    }
    for (node_produced_channels) |*list| list.* = .empty;

    for (pipeline.steps, 0..) |step, idx| {
        if (step == .task) {
            for (step.task.outputs) |out| {
                const ch_name = out.name;
                if (channel_map.contains(ch_name)) {
                    return error.SingleWriterViolation;
                }
                const ch_id = channels_list.items.len;
                try channels_list.append(allocator, ChannelSlot{
                    .id = ch_id,
                    .name = ch_name,
                    .producer_node = idx,
                    .consumers_count = 0,
                });
                try channel_map.put(allocator, ch_name, ch_id);
                try node_produced_channels[idx].append(allocator, ch_id);
            }
        }
    }

    // 3. Edge generation
    var raw_edges: std.ArrayListUnmanaged(PlanEdge) = .empty;
    defer raw_edges.deinit(allocator);

    var node_consumed_channels = try allocator.alloc(std.ArrayListUnmanaged(ChannelId), nodes_count);
    defer {
        for (node_consumed_channels) |*list| list.deinit(allocator);
        allocator.free(node_consumed_channels);
    }
    for (node_consumed_channels) |*list| list.* = .empty;

    var last_writer_by_datasource: std.StringHashMapUnmanaged(NodeId) = .empty;
    defer last_writer_by_datasource.deinit(allocator);

    for (pipeline.steps, 0..) |step, idx| {
        switch (step) {
            .task => |t| {
                var has_inbound_data_edge = false;

                // 3a. Explicit ordering: `after: [step_id, ...]`
                for (t.after) |dep_sid| {
                    const dep_node = step_id_map.get(dep_sid) orelse return error.UnknownStepDependency;
                    if (dep_node == idx) return error.CycleDetected;
                    try raw_edges.append(allocator, PlanEdge{
                        .from = dep_node,
                        .to = idx,
                        .kind = .ordering,
                    });
                }

                // 3b. Shared non-memory datasource write serialization (declaration order)
                for (t.outputs) |out| {
                    if (!isMemoryDatasource(out.datasource, ast_spec)) {
                        if (last_writer_by_datasource.get(out.datasource)) |prev_writer| {
                            if (prev_writer != idx) {
                                try raw_edges.append(allocator, PlanEdge{
                                    .from = prev_writer,
                                    .to = idx,
                                    .kind = .ordering,
                                });
                            }
                        }
                        try last_writer_by_datasource.put(allocator, out.datasource, idx);
                    }
                }

                // 3c. Data dependencies (`inputs:`)
                for (t.inputs) |in_bind| {
                    const resolved = try resolveDataEdges(
                        allocator,
                        in_bind.expr,
                        idx,
                        &step_id_map,
                        &channel_map,
                        channels_list.items,
                        &raw_edges,
                        &node_consumed_channels[idx],
                        ast_spec,
                    );
                    if (resolved) has_inbound_data_edge = true;
                }

                // 3d. Implicit chaining for steps without input bindings and without incoming edges
                if (!has_inbound_data_edge and t.inputs.len == 0 and idx > 0 and t.after.len == 0) {
                    // Check if any earlier step (< idx) depends on an output of step idx
                    var earlier_depends_on_idx = false;
                    for (node_produced_channels[idx].items) |prod_ch| {
                        for (0..idx) |earlier| {
                            for (node_consumed_channels[earlier].items) |cons_ch| {
                                if (cons_ch == prod_ch) {
                                    earlier_depends_on_idx = true;
                                    break;
                                }
                            }
                            if (earlier_depends_on_idx) break;
                        }
                        if (earlier_depends_on_idx) break;
                    }

                    if (!earlier_depends_on_idx) {
                        try raw_edges.append(allocator, PlanEdge{
                            .from = idx - 1,
                            .to = idx,
                            .kind = .implicit_chain,
                        });
                    }
                }
            },
            .router => {
                // 3e. Router barrier
                if (idx > 0) {
                    try raw_edges.append(allocator, PlanEdge{
                        .from = idx - 1,
                        .to = idx,
                        .kind = .router_barrier,
                    });
                }
                for ((idx + 1)..nodes_count) |later_idx| {
                    try raw_edges.append(allocator, PlanEdge{
                        .from = idx,
                        .to = later_idx,
                        .kind = .router_barrier,
                    });
                }
            },
        }
    }

    // 4. Deduplicate edges: retain single highest-priority edge per (from, to) pair
    var edge_matrix = try allocator.alloc(?EdgeKind, nodes_count * nodes_count);
    defer allocator.free(edge_matrix);
    @memset(edge_matrix, null);

    for (raw_edges.items) |e| {
        if (e.from == e.to) return error.CycleDetected;
        const cell_idx = e.from * nodes_count + e.to;
        if (edge_matrix[cell_idx]) |existing| {
            if (e.kind.priority() > existing.priority()) {
                edge_matrix[cell_idx] = e.kind;
            }
        } else {
            edge_matrix[cell_idx] = e.kind;
        }
    }

    var deduped_edges: std.ArrayListUnmanaged(PlanEdge) = .empty;
    defer deduped_edges.deinit(allocator);

    var node_succs = try allocator.alloc(std.ArrayListUnmanaged(NodeId), nodes_count);
    defer {
        for (node_succs) |*list| list.deinit(allocator);
        allocator.free(node_succs);
    }
    for (node_succs) |*list| list.* = .empty;

    var node_preds = try allocator.alloc(std.ArrayListUnmanaged(NodeId), nodes_count);
    defer {
        for (node_preds) |*list| list.deinit(allocator);
        allocator.free(node_preds);
    }
    for (node_preds) |*list| list.* = .empty;

    var indegrees = try allocator.alloc(usize, nodes_count);
    defer allocator.free(indegrees);
    @memset(indegrees, 0);

    for (0..nodes_count) |u| {
        for (0..nodes_count) |v| {
            const cell_idx = u * nodes_count + v;
            if (edge_matrix[cell_idx]) |k| {
                try deduped_edges.append(allocator, PlanEdge{
                    .from = u,
                    .to = v,
                    .kind = k,
                });
                try node_succs[u].append(allocator, v);
                try node_preds[v].append(allocator, u);
                indegrees[v] += 1;
            }
        }
    }

    // 5. Kahn's algorithm: Cycle Detection & Topological Sort
    var temp_indegree = try allocator.alloc(usize, nodes_count);
    defer allocator.free(temp_indegree);
    @memcpy(temp_indegree, indegrees);

    var ready_queue: std.ArrayListUnmanaged(NodeId) = .empty;
    defer ready_queue.deinit(allocator);

    for (0..nodes_count) |i| {
        if (temp_indegree[i] == 0) {
            try ready_queue.append(allocator, i);
        }
    }

    var topo_order: std.ArrayListUnmanaged(NodeId) = .empty;
    defer topo_order.deinit(allocator);

    var head: usize = 0;
    while (head < ready_queue.items.len) {
        const u = ready_queue.items[head];
        head += 1;
        try topo_order.append(allocator, u);

        for (node_succs[u].items) |v| {
            temp_indegree[v] -= 1;
            if (temp_indegree[v] == 0) {
                try ready_queue.append(allocator, v);
            }
        }
    }

    if (topo_order.items.len < nodes_count) {
        return error.CycleDetected;
    }

    // 6. Build final PlanNode array
    const final_nodes = try allocator.alloc(PlanNode, nodes_count);
    for (0..nodes_count) |i| {
        final_nodes[i] = PlanNode{
            .id = i,
            .step = pipeline.steps[i],
            .indegree = indegrees[i],
            .successors = try node_succs[i].toOwnedSlice(allocator),
            .predecessors = try node_preds[i].toOwnedSlice(allocator),
            .produced_channels = try node_produced_channels[i].toOwnedSlice(allocator),
            .consumed_channels = try node_consumed_channels[i].toOwnedSlice(allocator),
        };
    }

    return ExecutionPlan{
        .allocator = allocator,
        .pipeline_name = pipeline.name,
        .nodes = final_nodes,
        .edges = try deduped_edges.toOwnedSlice(allocator),
        .channels = try channels_list.toOwnedSlice(allocator),
        .topological_order = try topo_order.toOwnedSlice(allocator),
    };
}

fn resolveDataEdges(
    allocator: Allocator,
    expr: ast.InboundStreamExpr,
    consumer_idx: NodeId,
    step_id_map: *const std.StringHashMapUnmanaged(NodeId),
    channel_map: *const std.StringHashMapUnmanaged(ChannelId),
    channels: []ChannelSlot,
    edges: *std.ArrayListUnmanaged(PlanEdge),
    consumed_channels: *std.ArrayListUnmanaged(ChannelId),
    ast_spec: ast.PipelineAST,
) !bool {
    var matched_any = false;

    if (expr.stream_ref) |sref| {
        // ARCH-018: Ambient system streams (system.*, env.*) are not intra-DAG producer steps
        if (std.mem.startsWith(u8, sref, "system.") or std.mem.startsWith(u8, sref, "env.")) {
            return false;
        }

        if (std.mem.indexOfScalar(u8, sref, '.')) |dot_idx| {
            const prod_step_name = sref[0..dot_idx];
            const ch_name = sref[dot_idx + 1 ..];

            if (step_id_map.get(prod_step_name)) |prod_node| {
                if (channel_map.get(ch_name)) |ch_id| {
                    if (channels[ch_id].producer_node == prod_node) {
                        channels[ch_id].consumers_count += 1;
                        try consumed_channels.append(allocator, ch_id);
                    }
                }
                try edges.append(allocator, PlanEdge{
                    .from = prod_node,
                    .to = consumer_idx,
                    .kind = .data,
                });
                matched_any = true;
            } else if (isDeclaredInAnyPipeline(prod_step_name, ast_spec)) {
                // Cross-pipeline reference from a parent/routed pipeline in sub-pipelines
                matched_any = true;
            } else {
                return error.UnknownChannelReference;
            }
        } else {
            if (channel_map.get(sref)) |ch_id| {
                const prod_node = channels[ch_id].producer_node;
                try edges.append(allocator, PlanEdge{
                    .from = prod_node,
                    .to = consumer_idx,
                    .kind = .data,
                });
                channels[ch_id].consumers_count += 1;
                try consumed_channels.append(allocator, ch_id);
                matched_any = true;
            } else if (step_id_map.get(sref)) |prod_node| {
                // Direct step ID reference
                try edges.append(allocator, PlanEdge{
                    .from = prod_node,
                    .to = consumer_idx,
                    .kind = .data,
                });
                matched_any = true;
            } else if (isKnownExternalInput(sref)) {
                // Known pipeline external input
            } else if (isKnownDatasource(sref, ast_spec)) {
                // Known declared datasource input
            } else if (isDeclaredInAnyPipeline(sref, ast_spec)) {
                // Cross-pipeline reference
            } else {
                return error.UnknownChannelReference;
            }
        }
    }

    for (expr.sub_streams) |sub| {
        if (try resolveDataEdges(allocator, sub, consumer_idx, step_id_map, channel_map, channels, edges, consumed_channels, ast_spec)) {
            matched_any = true;
        }
    }

    return matched_any;
}

fn isDeclaredInAnyPipeline(sref: []const u8, ast_spec: ast.PipelineAST) bool {
    for (ast_spec.pipelines) |p| {
        for (p.steps) |st| {
            if (std.mem.eql(u8, st.id(), sref)) return true;
            if (st == .task) {
                for (st.task.outputs) |out| {
                    if (std.mem.eql(u8, out.name, sref)) return true;
                }
            }
        }
    }
    return false;
}

fn isKnownExternalInput(sref: []const u8) bool {
    return std.mem.eql(u8, sref, "input") or
        std.mem.eql(u8, sref, "input_payload") or
        std.mem.eql(u8, sref, "stream") or
        std.mem.eql(u8, sref, "primary") or
        std.mem.eql(u8, sref, "file") or
        std.mem.eql(u8, sref, "");
}

fn isKnownDatasource(sref: []const u8, ast_spec: ast.PipelineAST) bool {
    for (ast_spec.datasources) |ds| {
        if (std.mem.eql(u8, ds.id, sref)) return true;
    }
    return false;
}
