const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const extensions = @import("flowdata_extensions");

const kernel = flowdata.kernel;
const KernelContext = kernel.KernelContext;
const Extension = kernel.Extension;
const TelemetryEvent = kernel.TelemetryEvent;
const TelemetrySubscriber = kernel.TelemetrySubscriber;

test "Kernel Plane 1: Compiler & AST Pass Execution" {
    const alloc = std.testing.allocator;

    var k = try KernelContext.init(alloc);
    defer k.deinit();

    const AstCounterPass = struct {
        var passes_run: usize = 0;
        var total_pipelines: usize = 0;

        fn runPass(_: Allocator, ast: *flowdata.ast.PipelineAST) anyerror!void {
            passes_run += 1;
            total_pipelines = ast.pipelines.len;
        }
    };
    AstCounterPass.passes_run = 0;
    AstCounterPass.total_pipelines = 0;

    const ast_ext = Extension.fromStateless("test.ast_counter", struct {
        fn reg(ctx: *KernelContext) anyerror!void {
            try ctx.ast_passes.registerFn("counter", &AstCounterPass.runPass);
        }
    }.reg);

    try k.use(ast_ext);

    // Build a mock AST and run all passes
    var builder = flowdata.ast.PipelineBuilder.init(alloc);
    defer builder.deinit();

    try builder.addPipeline(.{
        .name = "main",
        .steps = &.{},
    });
    var ast = try builder.finish();

    try k.ast_passes.runAll(&ast);

    try std.testing.expectEqual(@as(usize, 1), AstCounterPass.passes_run);
    try std.testing.expectEqual(@as(usize, 1), AstCounterPass.total_pipelines);
}

test "Kernel Plane 2: TelemetryBus Zero-Overhead and Ordered Event Lifecycle" {
    const alloc = std.testing.allocator;

    var k = try KernelContext.init(alloc);
    defer k.deinit();

    // 1. Zero overhead when no subscribers are present
    try std.testing.expect(!k.telemetry.hasSubscribers());

    var dummy_trace: [16]u8 = undefined;
    var dummy_span: [8]u8 = undefined;
    @memset(&dummy_trace, 0xAA);
    @memset(&dummy_span, 0xBB);

    // Calling emit without subscribers should be a fast inline no-op
    k.telemetry.emit(.{
        .pipeline_start = .{
            .trace_id = dummy_trace,
            .span_id = dummy_span,
            .timestamp_ns = 12345,
            .ast = undefined,
            .input_bytes_len = 0,
        },
    });

    // 2. Attach a telemetry subscriber
    const EventCollector = struct {
        allocator: Allocator,
        events: std.ArrayListUnmanaged([]const u8) = .empty,
        observed_trace_id: ?[16]u8 = null,

        pub fn subscriber(self: *@This()) TelemetrySubscriber {
            const Self = @This();
            const Trampoline = struct {
                fn onEvent(ctx: *anyopaque, ev: *const TelemetryEvent) void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    switch (ev.*) {
                        .pipeline_start => |p| {
                            s.observed_trace_id = p.trace_id;
                            s.events.append(s.allocator, "pipeline_start") catch unreachable;
                        },
                        .step_start => |st| {
                            if (s.observed_trace_id) |tid| {
                                std.debug.assert(std.mem.eql(u8, &tid, &st.trace_id));
                            }
                            s.events.append(s.allocator, "step_start") catch unreachable;
                        },
                        .step_end => |se| {
                            if (s.observed_trace_id) |tid| {
                                std.debug.assert(std.mem.eql(u8, &tid, &se.trace_id));
                            }
                            s.events.append(s.allocator, "step_end") catch unreachable;
                        },
                        .router_decision => |rd| {
                            if (s.observed_trace_id) |tid| {
                                std.debug.assert(std.mem.eql(u8, &tid, &rd.trace_id));
                            }
                            s.events.append(s.allocator, "router_decision") catch unreachable;
                        },
                        .pipeline_end => |pe| {
                            if (s.observed_trace_id) |tid| {
                                std.debug.assert(std.mem.eql(u8, &tid, &pe.trace_id));
                            }
                            s.events.append(s.allocator, "pipeline_end") catch unreachable;
                        },
                        else => {},
                    }
                }
                const vtable = TelemetrySubscriber.VTable{
                    .onEvent = &onEvent,
                    .flush = null,
                    .deinit = null,
                };
            };
            return .{ .ptr = self, .vtable = &Trampoline.vtable };
        }
    };

    var collector = EventCollector{ .allocator = alloc };
    defer collector.events.deinit(alloc);

    try k.telemetry.subscribe(collector.subscriber());
    try std.testing.expect(k.telemetry.hasSubscribers());

    // Emit synthetic sequence of events sharing the same trace_id
    var test_trace_id: [16]u8 = undefined;
    @memset(&test_trace_id, 0x42);
    var span1: [8]u8 = undefined;
    @memset(&span1, 0x01);
    var span2: [8]u8 = undefined;
    @memset(&span2, 0x02);

    k.telemetry.emit(.{
        .pipeline_start = .{
            .trace_id = test_trace_id,
            .span_id = span1,
            .timestamp_ns = 1000,
            .ast = undefined,
            .input_bytes_len = 10,
        },
    });

    k.telemetry.emit(.{
        .step_start = .{
            .trace_id = test_trace_id,
            .span_id = span2,
            .parent_span_id = span1,
            .timestamp_ns = 2000,
            .pipeline_name = "main",
            .step_id = "step1",
            .module_name = "mod",
            .task_name = "task",
            .input_count = 1,
        },
    });

    k.telemetry.emit(.{
        .step_end = .{
            .trace_id = test_trace_id,
            .span_id = span2,
            .timestamp_ns = 3000,
            .duration_ns = 1000,
            .pipeline_name = "main",
            .step_id = "step1",
            .status = "ok",
            .output_count = 1,
        },
    });

    k.telemetry.emit(.{
        .router_decision = .{
            .trace_id = test_trace_id,
            .span_id = span2,
            .timestamp_ns = 4000,
            .pipeline_name = "main",
            .router_id = "router1",
            .matched_expression = null,
            .target_pipeline = "continue",
        },
    });

    k.telemetry.emit(.{
        .pipeline_end = .{
            .trace_id = test_trace_id,
            .span_id = span1,
            .timestamp_ns = 5000,
            .duration_ns = 4000,
            .steps_executed = 1,
            .routers_evaluated = 1,
            .halted_early = false,
            .final_pipeline = "main",
        },
    });

    try std.testing.expectEqual(@as(usize, 5), collector.events.items.len);
    try std.testing.expectEqualStrings("pipeline_start", collector.events.items[0]);
    try std.testing.expectEqualStrings("step_start", collector.events.items[1]);
    try std.testing.expectEqualStrings("step_end", collector.events.items[2]);
    try std.testing.expectEqualStrings("router_decision", collector.events.items[3]);
    try std.testing.expectEqualStrings("pipeline_end", collector.events.items[4]);
    try std.testing.expectEqual(test_trace_id, collector.observed_trace_id.?);
}

test "Kernel Plane 3: Custom Dispatcher Command Registration" {
    const alloc = std.testing.allocator;

    var k = try KernelContext.init(alloc);
    defer k.deinit();

    const PingExtension = struct {
        fn handlePing(_: Allocator, _: flowdata.transport.inbound.InvocationRequest) anyerror!flowdata.transport.inbound.InvocationResponse {
            return .{
                .status = .ok,
                .message = "pong",
                .output_bytes = "pong",
                .exit_code = 0,
            };
        }

        fn register(ctx: *KernelContext) anyerror!void {
            try ctx.commands.registerCommandFn("custom_ping", &handlePing);
        }
    };

    try k.use(Extension.fromStateless("ext.ping", &PingExtension.register));

    var dispatcher = flowdata.transport.inbound.InboundDispatcher.init(alloc, .{
        .app_name = "test_ping_app",
        .kernel = &k,
    });
    defer dispatcher.deinit();

    const resp = try dispatcher.handle(.{
        .command = .custom,
        .custom_command_name = "custom_ping",
        .options = .{ .pipeline_yaml_path = "" },
    });
    try std.testing.expectEqual(flowdata.transport.inbound.InvocationStatus.ok, resp.status);
    try std.testing.expectEqualStrings("pong", resp.message);
}

test "Kernel Plane 4: DSL Custom Secret Scheme and Predicate Functions" {
    const alloc = std.testing.allocator;

    var k = try KernelContext.init(alloc);
    defer k.deinit();

    const DslTestExtension = struct {
        fn mockSecretResolver(_: Allocator, key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "api_token")) {
                return "secret_12345";
            }
            return null;
        }

        fn isEvenPredicate(arg: flowdata.dataflow.ReflectedValue, _: []const u8) bool {
            if (arg.asInt()) |v| {
                return @mod(v, 2) == 0;
            }
            return false;
        }

        fn register(ctx: *KernelContext) anyerror!void {
            try ctx.dsl.registerEnvScheme("mock_secret", &mockSecretResolver);
            try ctx.dsl.registerPredicateFn("is_even", &isEvenPredicate);
        }
    };

    try k.use(Extension.fromStateless("ext.dsl_test", &DslTestExtension.register));

    // 1. Verify custom env scheme interpolation: ${mock_secret:api_token}
    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const S = struct {
        var kernel_ref: *KernelContext = undefined;
        fn resolve(a: Allocator, scheme: []const u8, key: []const u8) ?[]const u8 {
            return kernel_ref.dsl.resolveEnvScheme(a, scheme, key);
        }
    };
    S.kernel_ref = &k;
    env_interp.scheme_resolver = &S.resolve;

    const interpolated = try env_interp.interpolate(alloc, "Bearer ${mock_secret:api_token}");
    defer alloc.free(interpolated);
    try std.testing.expectEqualStrings("Bearer secret_12345", interpolated);

    // 2. Verify custom predicate function: is_even(num)
    const PredicateEvaluator = struct {
        var kernel_ref: *KernelContext = undefined;
        fn eval(fn_name: []const u8, arg: flowdata.dataflow.ReflectedValue, param: []const u8) ?bool {
            return kernel_ref.dsl.evaluatePredicate(fn_name, arg, param);
        }
    };
    PredicateEvaluator.kernel_ref = &k;
    flowdata.dataflow.predicate.global_custom_predicate_evaluator = &PredicateEvaluator.eval;

    const TestItem = struct {
        val: i64,
    };
    const even_item = TestItem{ .val = 42 };
    const odd_item = TestItem{ .val = 43 };

    try std.testing.expect(flowdata.dataflow.predicate.evaluatePredicate(TestItem, &even_item, "is_even(val)"));
    try std.testing.expect(!flowdata.dataflow.predicate.evaluatePredicate(TestItem, &odd_item, "is_even(val)"));
}

test "Kernel Plane 5: Declarative Extension Registration of Datasources" {
    const alloc = std.testing.allocator;

    var k = try KernelContext.init(alloc);
    defer k.deinit();

    // Register official datasource extension
    try k.use(extensions.datasource.extension);

    // Verify drivers registered in kernel.datasources
    try std.testing.expect(k.datasources.drivers.contains("memory"));
    try std.testing.expect(k.datasources.drivers.contains("file_store"));
    try std.testing.expect(k.datasources.drivers.contains("sqlite"));
}
