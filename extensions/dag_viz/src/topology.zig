const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const PipelineAST = flowdata.ast.PipelineAST;

pub const DagNodeKind = enum {
    task_step,
    router_step,
    datasource,
    network,
    sub_pipeline,
};

pub const DagEdgeKind = enum {
    sequential,
    data_flow,
    branch_condition,
    default_branch,
    network_link,
    datasource_sink,
};

pub const DagNode = struct {
    id: []const u8,
    name: []const u8,
    kind: DagNodeKind,
    pipeline_name: []const u8,
    filter_expr: ?[]const u8 = null,
    network_id: ?[]const u8 = null,
    duration_ns: u64 = 0,
    rows_in: u64 = 0,
    rows_out: u64 = 0,

    pub fn deinit(self: *DagNode, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.pipeline_name);
        if (self.filter_expr) |f| allocator.free(f);
        if (self.network_id) |n| allocator.free(n);
    }
};

pub const DagEdge = struct {
    from_node_id: []const u8,
    to_node_id: []const u8,
    kind: DagEdgeKind,
    label: ?[]const u8 = null,
    taken: bool = false,

    pub fn deinit(self: *DagEdge, allocator: Allocator) void {
        allocator.free(self.from_node_id);
        allocator.free(self.to_node_id);
        if (self.label) |l| allocator.free(l);
    }
};

pub const DagTopologyGraph = struct {
    allocator: Allocator,
    nodes: std.ArrayListUnmanaged(DagNode) = .empty,
    edges: std.ArrayListUnmanaged(DagEdge) = .empty,

    pub fn init(allocator: Allocator) DagTopologyGraph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DagTopologyGraph) void {
        for (self.nodes.items) |*n| {
            n.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);

        for (self.edges.items) |*e| {
            e.deinit(self.allocator);
        }
        self.edges.deinit(self.allocator);
    }

    pub fn addNode(self: *DagTopologyGraph, node: DagNode) !void {
        try self.nodes.append(self.allocator, node);
    }

    pub fn addEdge(self: *DagTopologyGraph, edge: DagEdge) !void {
        try self.edges.append(self.allocator, edge);
    }

    pub fn findNode(self: *const DagTopologyGraph, id: []const u8) ?*DagNode {
        for (self.nodes.items) |*n| {
            if (std.mem.eql(u8, n.id, id)) return n;
        }
        return null;
    }

    pub fn build(allocator: Allocator, ast: *const PipelineAST) !DagTopologyGraph {
        var g = DagTopologyGraph.init(allocator);
        errdefer g.deinit();

        // 1. Add Datasources as nodes
        for (ast.datasources) |ds| {
            const ds_id = try std.fmt.allocPrint(allocator, "ds_{s}", .{ds.id});
            try g.addNode(.{
                .id = ds_id,
                .name = try allocator.dupe(u8, ds.id),
                .kind = .datasource,
                .pipeline_name = try allocator.dupe(u8, "global"),
            });
        }

        // 2. Add Networks as nodes
        for (ast.networks) |net| {
            const net_id = try std.fmt.allocPrint(allocator, "net_{s}", .{net.id});
            try g.addNode(.{
                .id = net_id,
                .name = try allocator.dupe(u8, net.id),
                .kind = .network,
                .pipeline_name = try allocator.dupe(u8, "global"),
            });
        }

        // 3. Add Pipelines and their Steps
        for (ast.pipelines) |pipe| {
            var prev_step_node_id: ?[]const u8 = null;

            for (pipe.steps) |step| {
                switch (step) {
                    .task => |ts| {
                        const step_node_id = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ pipe.name, ts.id });
                        const step_name = try std.fmt.allocPrint(allocator, "{s} ({s}/{s})", .{ ts.id, ts.module, ts.task });
                        const filter_copy = if (ts.where_filter) |f| try allocator.dupe(u8, f) else null;
                        const net_copy = if (ts.networks.len > 0) try allocator.dupe(u8, ts.networks[0]) else null;

                        try g.addNode(.{
                            .id = step_node_id,
                            .name = step_name,
                            .kind = .task_step,
                            .pipeline_name = try allocator.dupe(u8, pipe.name),
                            .filter_expr = filter_copy,
                            .network_id = net_copy,
                        });

                        // Sequential edge from previous step in the same pipeline
                        if (prev_step_node_id) |prev_id| {
                            try g.addEdge(.{
                                .from_node_id = try allocator.dupe(u8, prev_id),
                                .to_node_id = try allocator.dupe(u8, step_node_id),
                                .kind = .sequential,
                            });
                        }

                        // Edge to network adapter if step is network-bound
                        for (ts.networks) |net_name| {
                            const target_net_id = try std.fmt.allocPrint(allocator, "net_{s}", .{net_name});
                            try g.addEdge(.{
                                .from_node_id = try allocator.dupe(u8, step_node_id),
                                .to_node_id = target_net_id,
                                .kind = .network_link,
                                .label = try allocator.dupe(u8, "net_io"),
                            });
                        }

                        // Edges to datasources for outputs
                        for (ts.outputs) |out| {
                            const target_ds_id = try std.fmt.allocPrint(allocator, "ds_{s}", .{out.datasource});
                            try g.addEdge(.{
                                .from_node_id = try allocator.dupe(u8, step_node_id),
                                .to_node_id = target_ds_id,
                                .kind = .datasource_sink,
                                .label = try allocator.dupe(u8, out.name),
                            });
                        }

                        prev_step_node_id = step_node_id;
                    },
                    .router => |rs| {
                        const router_node_id = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ pipe.name, rs.id });
                        try g.addNode(.{
                            .id = router_node_id,
                            .name = try std.fmt.allocPrint(allocator, "router:{s}", .{rs.id}),
                            .kind = .router_step,
                            .pipeline_name = try allocator.dupe(u8, pipe.name),
                        });

                        if (prev_step_node_id) |prev_id| {
                            try g.addEdge(.{
                                .from_node_id = try allocator.dupe(u8, prev_id),
                                .to_node_id = try allocator.dupe(u8, router_node_id),
                                .kind = .sequential,
                            });
                        }

                        // Router conditional branching edges
                        for (rs.cases) |c| {
                            const target_node_id = try std.fmt.allocPrint(allocator, "{s}_entry", .{c.goto_pipeline});
                            try g.addEdge(.{
                                .from_node_id = try allocator.dupe(u8, router_node_id),
                                .to_node_id = target_node_id,
                                .kind = .branch_condition,
                                .label = try allocator.dupe(u8, c.when_predicate),
                            });
                        }

                        if (rs.default_pipeline) |def_pipe| {
                            const target_def_id = try std.fmt.allocPrint(allocator, "{s}_entry", .{def_pipe});
                            try g.addEdge(.{
                                .from_node_id = try allocator.dupe(u8, router_node_id),
                                .to_node_id = target_def_id,
                                .kind = .default_branch,
                                .label = try allocator.dupe(u8, "default"),
                            });
                        }

                        prev_step_node_id = router_node_id;
                    },
                }
            }
        }

        return g;
    }
};
