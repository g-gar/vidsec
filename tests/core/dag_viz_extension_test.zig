const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const extensions = @import("flowdata_extensions");

const kernel = flowdata.kernel;
const KernelContext = kernel.KernelContext;
const ast = flowdata.ast;
const dag_viz = extensions.dag_viz;
const DagVizExtension = dag_viz.DagVizExtension;
const DagTopologyGraph = dag_viz.DagTopologyGraph;

test "DAG Visualizer: Topological Graph Extraction from PipelineAST" {
    const alloc = std.testing.allocator;

    var builder = ast.PipelineBuilder.init(alloc);
    defer builder.deinit();

    try builder.addDatasource(.{
        .id = "mem_store",
        .driver = "memory",
    });

    try builder.addNetwork(.{
        .id = "api_egress",
        .driver = .egress,
    });

    try builder.addPipeline(.{
        .name = "quarantine_flow",
        .steps = &.{
            .{
                .task = .{
                    .id = "step_isolate",
                    .module = "forensics",
                    .task = "isolate",
                },
            },
        },
    });

    try builder.addPipeline(.{
        .name = "main",
        .steps = &.{
            .{
                .task = .{
                    .id = "step_scrape",
                    .module = "scraper",
                    .task = "fetch",
                    .networks = &.{"api_egress"},
                    .outputs = &.{
                        .{
                            .name = "scraped_docs",
                            .datasource = "mem_store",
                        },
                    },
                },
            },
            .{
                .router = .{
                    .id = "check_malice",
                    .cases = &.{
                        .{
                            .when_predicate = "is_suspicious == true",
                            .goto_pipeline = "quarantine_flow",
                        },
                    },
                    .default_pipeline = "continue",
                },
            },
        },
    });

    var parsed_ast = try builder.finish();

    // 1. Build topology graph
    var graph = try DagTopologyGraph.build(alloc, &parsed_ast);
    defer graph.deinit();

    // Verify nodes: 1 datasource + 1 network + 2 main steps + 1 quarantine step = 5 nodes
    try std.testing.expectEqual(@as(usize, 5), graph.nodes.items.len);

    // Verify Mermaid Export
    const mermaid = try dag_viz.renderMermaid(alloc, &graph);
    defer alloc.free(mermaid);
    try std.testing.expect(std.mem.startsWith(u8, mermaid, "flowchart TD"));
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "api_egress") != null);
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "mem_store") != null);
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "step_scrape") != null);
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "is_suspicious == true") != null);

    // Verify DOT Export
    const dot = try dag_viz.renderDot(alloc, &graph);
    defer alloc.free(dot);
    try std.testing.expect(std.mem.startsWith(u8, dot, "digraph FlowdataDAG"));
    try std.testing.expect(std.mem.indexOf(u8, dot, "check_malice") != null);

    // Verify Standalone Interactive HTML5 Export
    const html = try dag_viz.renderHtml(alloc, &graph);
    defer alloc.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<svg id=\"dag-svg\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Pipeline Inspector") != null);
}

test "DAG Visualizer: Kernel Command Dispatching and Inbound Integration" {
    const alloc = std.testing.allocator;

    var k = try KernelContext.init(alloc);
    defer k.deinit();

    var dag_inst = DagVizExtension.init(alloc);
    defer dag_inst.deinit();

    try k.use(dag_inst.extension());

    // Build mock AST
    var builder = ast.PipelineBuilder.init(alloc);
    defer builder.deinit();
    try builder.addPipeline(.{
        .name = "main",
        .steps = &.{},
    });
    var parsed_ast = try builder.finish();

    // Pass through AST passes (captures AST into dag_inst)
    try k.ast_passes.runAll(&parsed_ast);

    // Invoke 'graph' custom command via InboundDispatcher
    var in_disp = flowdata.transport.inbound.InboundDispatcher.init(alloc, .{
        .app_name = "test_app",
        .version = "1.0.0",
        .kernel = &k,
    });
    defer in_disp.deinit();

    const resp = try in_disp.handle(.{
        .command = .custom,
        .custom_command_name = "graph",
        .options = .{
            .pipeline_yaml_path = "",
        },
        .extra_params = &.{
            .{ .key = "format", .value = "mermaid" },
        },
    });
    defer alloc.free(resp.message);

    try std.testing.expectEqual(flowdata.transport.inbound.InvocationStatus.ok, resp.status);
    try std.testing.expect(std.mem.startsWith(u8, resp.message, "flowchart TD"));
}
