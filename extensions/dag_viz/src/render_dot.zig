const std = @import("std");
const Allocator = std.mem.Allocator;
const topology = @import("topology.zig");
const DagTopologyGraph = topology.DagTopologyGraph;

pub fn renderDot(allocator: Allocator, graph: *const DagTopologyGraph) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "digraph FlowdataDAG {\n  rankdir=TB;\n  node [fontname=\"sans-serif\", fontsize=10];\n  edge [fontname=\"sans-serif\", fontsize=9];\n\n");

    for (graph.nodes.items) |node| {
        try out.appendSlice(allocator, "  \"");
        try out.appendSlice(allocator, node.id);
        try out.appendSlice(allocator, "\" [label=\"");
        try out.appendSlice(allocator, node.name);
        try out.appendSlice(allocator, "\"");

        switch (node.kind) {
            .task_step => {
                try out.appendSlice(allocator, ", shape=box, style=rounded");
            },
            .router_step => {
                try out.appendSlice(allocator, ", shape=diamond");
            },
            .datasource => {
                try out.appendSlice(allocator, ", shape=cylinder");
            },
            .network => {
                try out.appendSlice(allocator, ", shape=ellipse");
            },
            .sub_pipeline => {
                try out.appendSlice(allocator, ", shape=component");
            },
        }

        try out.appendSlice(allocator, "];\n");
    }

    try out.appendSlice(allocator, "\n");

    for (graph.edges.items) |edge| {
        try out.appendSlice(allocator, "  \"");
        try out.appendSlice(allocator, edge.from_node_id);
        try out.appendSlice(allocator, "\" -> \"");
        try out.appendSlice(allocator, edge.to_node_id);
        try out.appendSlice(allocator, "\"");

        if (edge.label) |lbl| {
            try out.appendSlice(allocator, " [label=\"");
            try out.appendSlice(allocator, lbl);
            try out.appendSlice(allocator, "\"]");
        }

        try out.appendSlice(allocator, ";\n");
    }

    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}
