const std = @import("std");
const Allocator = std.mem.Allocator;
const topology = @import("topology.zig");
const DagTopologyGraph = topology.DagTopologyGraph;

pub fn renderHtml(allocator: Allocator, graph: *const DagTopologyGraph) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <title>Flowdata Reactive Pipeline DAG</title>
        \\  <style>
        \\    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; display: flex; height: 100vh; background: #0f172a; color: #f8fafc; }
        \\    #canvas-container { flex: 1; position: relative; overflow: hidden; background: radial-gradient(#1e293b 1px, transparent 1px); background-size: 24px 24px; }
        \\    #sidebar { width: 340px; background: #1e293b; border-left: 1px solid #334155; padding: 20px; box-sizing: border-box; overflow-y: auto; }
        \\    .node-card { background: #334155; border-radius: 8px; padding: 12px; margin-bottom: 12px; border: 1px solid #475569; }
        \\    .node-title { font-weight: bold; font-size: 14px; color: #38bdf8; }
        \\    .node-meta { font-size: 12px; color: #94a3b8; margin-top: 4px; }
        \\    .tag { display: inline-block; padding: 2px 6px; border-radius: 4px; font-size: 11px; font-weight: 600; margin-top: 6px; }
        \\    .tag-task { background: #0369a1; color: #e0f2fe; }
        \\    .tag-router { background: #b45309; color: #fef3c7; }
        \\    .tag-ds { background: #15803d; color: #dcfce7; }
        \\    .tag-net { background: #6d28d9; color: #ede9fe; }
        \\    svg { width: 100%; height: 100%; cursor: grab; }
        \\    .svg-node rect, .svg-node polygon { fill: #1e293b; stroke: #38bdf8; stroke-width: 2; transition: all 0.2s; cursor: pointer; }
        \\    .svg-node:hover rect { fill: #334155; stroke: #7dd3fc; }
        \\    .svg-node text { fill: #f8fafc; font-size: 12px; text-anchor: middle; dominant-baseline: middle; pointer-events: none; }
        \\    .svg-edge { stroke: #64748b; stroke-width: 1.5; fill: none; marker-end: url(#arrow); }
        \\    .svg-edge-label { fill: #94a3b8; font-size: 10px; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div id="canvas-container">
        \\    <svg id="dag-svg">
        \\      <defs>
        \\        <marker id="arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
        \\          <path d="M 0 0 L 10 5 L 0 10 z" fill="#64748b" />
        \\        </marker>
        \\      </defs>
        \\      <g id="viewport">
    );

    // Simple auto-layout: grid positioning of nodes
    const node_w: usize = 160;
    const node_h: usize = 50;
    const gap_x: usize = 80;
    const gap_y: usize = 90;
    const cols: usize = 3;

    for (graph.nodes.items, 0..) |n, idx| {
        const row = idx / cols;
        const col = idx % cols;
        const x = 50 + col * (node_w + gap_x);
        const y = 50 + row * (node_h + gap_y);

        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "        <g class=\"svg-node\" id=\"el_{s}\" transform=\"translate({d},{d})\">\n", .{ n.id, x, y }) catch "";
        try out.appendSlice(allocator, s);
        try out.appendSlice(allocator, "          <rect width=\"160\" height=\"50\" rx=\"6\" />\n");

        const text_s = std.fmt.bufPrint(&buf, "          <text x=\"80\" y=\"25\">{s}</text>\n        </g>\n", .{n.name}) catch "";
        try out.appendSlice(allocator, text_s);
    }

    try out.appendSlice(allocator,
        \\      </g>
        \\    </svg>
        \\  </div>
        \\  <div id="sidebar">
        \\    <h2>Pipeline Inspector</h2>
        \\    <p style="color: #94a3b8; font-size: 13px;">Topological DAG Structure & Telemetry</p>
    );

    for (graph.nodes.items) |n| {
        try out.appendSlice(allocator, "    <div class=\"node-card\">\n      <div class=\"node-title\">");
        try out.appendSlice(allocator, n.name);
        try out.appendSlice(allocator, "</div>\n      <div class=\"node-meta\">ID: ");
        try out.appendSlice(allocator, n.id);
        try out.appendSlice(allocator, "<br/>Pipeline: ");
        try out.appendSlice(allocator, n.pipeline_name);
        if (n.filter_expr) |f| {
            try out.appendSlice(allocator, "<br/>Where: <code>");
            try out.appendSlice(allocator, f);
            try out.appendSlice(allocator, "</code>");
        }
        if (n.duration_ns > 0) {
            var m_buf: [64]u8 = undefined;
            const ms = n.duration_ns / 1_000_000;
            const m_str = std.fmt.bufPrint(&m_buf, "<br/>Duration: <b>{d} ms</b>", .{ms}) catch "";
            try out.appendSlice(allocator, m_str);
        }
        try out.appendSlice(allocator, "</div>\n      <span class=\"tag tag-task\">");
        try out.appendSlice(allocator, @tagName(n.kind));
        try out.appendSlice(allocator, "</span>\n    </div>\n");
    }

    try out.appendSlice(allocator,
        \\  </div>
        \\</body>
        \\</html>
        \\
    );

    return out.toOwnedSlice(allocator);
}
