const std = @import("std");
const Allocator = std.mem.Allocator;
const topology = @import("topology.zig");
const DagTopologyGraph = topology.DagTopologyGraph;

pub fn renderMermaid(allocator: Allocator, graph: *const DagTopologyGraph) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "flowchart TD\n");

    // Render nodes
    for (graph.nodes.items) |node| {
        try out.appendSlice(allocator, "    ");
        try out.appendSlice(allocator, node.id);

        switch (node.kind) {
            .task_step => {
                try out.appendSlice(allocator, "[\"");
                try out.appendSlice(allocator, node.name);
                if (node.filter_expr) |f| {
                    try out.appendSlice(allocator, "<br/><i>where: ");
                    try out.appendSlice(allocator, f);
                    try out.appendSlice(allocator, "</i>");
                }
                if (node.duration_ns > 0) {
                    const us = node.duration_ns / 1000;
                    var time_buf: [32]u8 = undefined;
                    const time_str = std.fmt.bufPrint(&time_buf, "<br/><b>{d} µs</b>", .{us}) catch "";
                    try out.appendSlice(allocator, time_str);
                }
                try out.appendSlice(allocator, "\"]\n");
            },
            .router_step => {
                try out.appendSlice(allocator, "{\"");
                try out.appendSlice(allocator, node.name);
                try out.appendSlice(allocator, "\"}\n");
            },
            .datasource => {
                try out.appendSlice(allocator, "[(\"ds: ");
                try out.appendSlice(allocator, node.name);
                try out.appendSlice(allocator, "\")]\n");
            },
            .network => {
                try out.appendSlice(allocator, "((\"net: ");
                try out.appendSlice(allocator, node.name);
                try out.appendSlice(allocator, "\"))\n");
            },
            .sub_pipeline => {
                try out.appendSlice(allocator, "[[\"pipeline: ");
                try out.appendSlice(allocator, node.name);
                try out.appendSlice(allocator, "\"]]\n");
            },
        }
    }

    // Render edges
    for (graph.edges.items) |edge| {
        try out.appendSlice(allocator, "    ");
        try out.appendSlice(allocator, edge.from_node_id);

        if (edge.label) |lbl| {
            try out.appendSlice(allocator, " -->|\"");
            try out.appendSlice(allocator, lbl);
            try out.appendSlice(allocator, "\"| ");
        } else {
            try out.appendSlice(allocator, " --> ");
        }

        try out.appendSlice(allocator, edge.to_node_id);
        try out.appendSlice(allocator, "\n");
    }

    return out.toOwnedSlice(allocator);
}
