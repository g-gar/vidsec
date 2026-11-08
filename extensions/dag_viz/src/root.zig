const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const kernel = flowdata.kernel;
const KernelContext = kernel.KernelContext;
const Extension = kernel.Extension;
const TelemetryEvent = kernel.TelemetryEvent;
const TelemetrySubscriber = kernel.TelemetrySubscriber;
const PipelineAST = flowdata.ast.PipelineAST;
const InvocationRequest = flowdata.transport.inbound.InvocationRequest;
const InvocationResponse = flowdata.transport.inbound.InvocationResponse;
const InvocationStatus = flowdata.transport.inbound.InvocationStatus;

pub const topology = @import("topology.zig");
pub const render_mermaid = @import("render_mermaid.zig");
pub const render_dot = @import("render_dot.zig");
pub const render_html = @import("render_html.zig");

pub const DagTopologyGraph = topology.DagTopologyGraph;
pub const renderMermaid = render_mermaid.renderMermaid;
pub const renderDot = render_dot.renderDot;
pub const renderHtml = render_html.renderHtml;

pub const DagVizExtension = struct {
    allocator: Allocator,
    cached_graph: ?DagTopologyGraph = null,

    pub fn init(allocator: Allocator) DagVizExtension {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DagVizExtension) void {
        if (self.cached_graph) |*g| {
            g.deinit();
            self.cached_graph = null;
        }
    }

    pub fn setAst(self: *DagVizExtension, ast: *const PipelineAST) !void {
        if (self.cached_graph) |*g| {
            g.deinit();
            self.cached_graph = null;
        }
        self.cached_graph = try DagTopologyGraph.build(self.allocator, ast);
    }

    pub fn onEvent(self: *DagVizExtension, event: *const TelemetryEvent) void {
        if (self.cached_graph == null) return;
        var g = &self.cached_graph.?;

        switch (event.*) {
            .step_end => |se| {
                const target_id = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ se.pipeline_name, se.step_id }) catch return;
                defer self.allocator.free(target_id);

                if (g.findNode(target_id)) |n| {
                    n.duration_ns += se.duration_ns;
                    n.rows_out += se.output_count;
                }
            },
            .router_decision => |rd| {
                const router_id = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ rd.pipeline_name, rd.router_id }) catch return;
                defer self.allocator.free(router_id);

                for (g.edges.items) |*edge| {
                    if (std.mem.eql(u8, edge.from_node_id, router_id)) {
                        if (rd.matched_expression) |expr| {
                            if (edge.label) |lbl| {
                                if (std.mem.eql(u8, lbl, expr)) {
                                    edge.taken = true;
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    pub fn handleCommand(self: *DagVizExtension, req: InvocationRequest) !InvocationResponse {
        var format: []const u8 = "mermaid";
        for (req.extra_params) |p| {
            if (std.mem.eql(u8, p.key, "format")) {
                format = p.value;
                break;
            }
        }

        if (self.cached_graph == null) {
            return InvocationResponse{
                .status = .invalid_request,
                .message = "No Pipeline AST loaded. Run or inspect a pipeline first.",
            };
        }

        const g = &self.cached_graph.?;
        const rendered = if (std.mem.indexOf(u8, format, "dot") != null)
            try renderDot(self.allocator, g)
        else if (std.mem.indexOf(u8, format, "html") != null)
            try renderHtml(self.allocator, g)
        else
            try renderMermaid(self.allocator, g);

        return InvocationResponse{
            .status = .ok,
            .message = rendered,
        };
    }

    pub fn subscriber(self: *DagVizExtension) TelemetrySubscriber {
        const Trampoline = struct {
            fn doOnEvent(ctx: *anyopaque, event: *const TelemetryEvent) void {
                const s: *DagVizExtension = @ptrCast(@alignCast(ctx));
                s.onEvent(event);
            }

            const vtable = TelemetrySubscriber.VTable{
                .onEvent = &doOnEvent,
                .flush = null,
                .deinit = null,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }

    pub fn extension(self: *DagVizExtension) Extension {
        const Trampoline = struct {
            fn getName(_: *const anyopaque) []const u8 {
                return "flowdata.dag_viz";
            }

            fn register(ctx_ptr: *anyopaque, k: *KernelContext) anyerror!void {
                const s: *DagVizExtension = @ptrCast(@alignCast(ctx_ptr));

                // 1. Register AST Pass to capture the topology
                const AstPassHolder = struct {
                    var self_ref: *DagVizExtension = undefined;
                    fn pass(_: Allocator, ast_ptr: *PipelineAST) anyerror!void {
                        try self_ref.setAst(ast_ptr);
                    }
                };
                AstPassHolder.self_ref = s;
                try k.ast_passes.registerFn("dag_viz_ast_capture", &AstPassHolder.pass);

                // 2. Register Telemetry Subscriber
                try k.telemetry.subscribe(s.subscriber());

                // 3. Register custom command 'graph'
                const CmdHolder = struct {
                    var self_ref: *DagVizExtension = undefined;
                    fn cmdHandler(_: Allocator, req: InvocationRequest) anyerror!InvocationResponse {
                        return try self_ref.handleCommand(req);
                    }
                };
                CmdHolder.self_ref = s;
                try k.commands.registerCommandFn("graph", &CmdHolder.cmdHandler);
            }

            fn deinitExt(ctx_ptr: *anyopaque, _: Allocator) void {
                const s: *DagVizExtension = @ptrCast(@alignCast(ctx_ptr));
                s.deinit();
            }

            const vtable = Extension.VTable{
                .name = &getName,
                .register = &register,
                .deinit = &deinitExt,
            };
        };
        return .{
            .ptr = self,
            .vtable = &Trampoline.vtable,
        };
    }
};

var global_dag_instance: ?DagVizExtension = null;

pub fn getGlobalDag(allocator: Allocator) *DagVizExtension {
    if (global_dag_instance == null) {
        global_dag_instance = DagVizExtension.init(allocator);
    }
    return &global_dag_instance.?;
}

pub const extension = Extension.fromStateless("flowdata.dag_viz", struct {
    fn reg(k: *KernelContext) anyerror!void {
        const ext = getGlobalDag(k.allocator);
        try k.use(ext.extension());
    }
}.reg);
