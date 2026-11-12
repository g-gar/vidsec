//! Pluggable RoutingStrategy & RouterRegistry Tests (ARCH-023 Phase 2).
//!
//! Validates the decoupled RoutingStrategy vtable contract and RouterRegistry
//! using a pure in-memory MockRouter with zero WorkerPool, network, or I/O.

const std = @import("std");
const testing = std.testing;
const flowdata = @import("flowdata");
const plugin = @import("flowdata_plugin");
const routing = flowdata.routing;

const MockRouter = struct {
    allocator: std.mem.Allocator,
    pending: usize = 0,
    deinit_called: *bool,

    pub fn onPipelineStart(self: *MockRouter, alloc: std.mem.Allocator, initial_input: flowdata.dataflow.PayloadHandle) ![]routing.TaskActivation {
        self.pending = 1;
        const out = try alloc.alloc(routing.TaskActivation, 1);
        out[0] = .{
            .node_id = 0,
            .step_input = initial_input,
        };
        return out;
    }

    pub fn onStepComplete(self: *MockRouter, alloc: std.mem.Allocator, event: routing.StepOutcomeEvent) ![]routing.TaskActivation {
        if (self.pending > 0) self.pending -= 1;
        if (event.node_id == 0 and event.status == .ok) {
            self.pending += 1;
            const out = try alloc.alloc(routing.TaskActivation, 1);
            out[0] = .{
                .node_id = 1,
                .step_input = event.output,
            };
            return out;
        }
        return &.{};
    }

    pub fn hasPendingWork(self: *const MockRouter) bool {
        return self.pending > 0;
    }

    pub fn deinit(self: *MockRouter) void {
        self.deinit_called.* = true;
        self.allocator.destroy(self);
    }
};

test "ARCH-023 Phase 2: RoutingStrategy vtable + RouterRegistry with MockRouter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var deinit_flag = false;

    const Factory = struct {
        var flag_ptr: *bool = undefined;

        fn create(ctx: routing.RoutingContext) !routing.RoutingStrategy {
            const impl = try ctx.allocator.create(MockRouter);
            impl.* = .{
                .allocator = ctx.allocator,
                .deinit_called = flag_ptr,
            };
            return routing.RoutingStrategy.fromImpl(MockRouter, impl);
        }
    };
    Factory.flag_ptr = &deinit_flag;

    var reg = routing.RouterRegistry.init(alloc);
    defer reg.deinit();

    try reg.register("directed", &Factory.create);
    try testing.expect(reg.has("directed"));
    try testing.expect(!reg.has("nonexistent"));

    var mod_reg = flowdata.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    var ambient = flowdata.AmbientContext.init(alloc);

    var builder = flowdata.PipelineBuilder.init(alloc);
    defer builder.deinit();
    try builder.addPipeline(.{ .name = "mock_pipe", .steps = &.{} });
    const ast = try builder.finish();

    const rctx = routing.RoutingContext{
        .allocator = alloc,
        .ast = ast,
        .pipeline = ast.getPipeline("mock_pipe").?,
        .modules = &mod_reg,
        .ambient = &ambient,
    };

    try testing.expectError(error.UnknownRoutingStrategy, reg.create("missing", rctx));

    const strategy = try reg.createForMode(.directed, rctx);

    const DummyItem = struct { id: u32 };
    const item = DummyItem{ .id = 42 };
    const payload = flowdata.dataflow.PayloadHandle.fromScalar(DummyItem, &item);

    const start_acts = try strategy.onPipelineStart(alloc, payload);
    try testing.expectEqual(@as(usize, 1), start_acts.len);
    try testing.expectEqual(@as(routing.NodeId, 0), start_acts[0].node_id);
    try testing.expect(strategy.hasPendingWork());

    const next_acts = try strategy.onStepComplete(alloc, .{
        .node_id = 0,
        .status = .ok,
        .output = payload,
    });
    try testing.expectEqual(@as(usize, 1), next_acts.len);
    try testing.expectEqual(@as(routing.NodeId, 1), next_acts[0].node_id);
    try testing.expect(strategy.hasPendingWork());

    const done_acts = try strategy.onStepComplete(alloc, .{
        .node_id = 1,
        .status = .ok,
        .output = payload,
    });
    try testing.expectEqual(@as(usize, 0), done_acts.len);
    try testing.expect(!strategy.hasPendingWork());

    strategy.deinit();
    try testing.expect(deinit_flag);
}

test "ARCH-023 Phase 3: DirectedRouter executes diamond Fork/Join purely without WorkerPool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\pipelines:
        \\  diamond:
        \\    routing: directed
        \\    steps:
        \\      - id: root
        \\        uses: mod/root
        \\        outputs:
        \\          root_out:
        \\            datasource: memory
        \\      - id: branch_a
        \\        uses: mod/a
        \\        inputs:
        \\          input: root_out
        \\        outputs:
        \\          out_a:
        \\            datasource: memory
        \\      - id: branch_b
        \\        uses: mod/b
        \\        inputs:
        \\          input: root_out
        \\        outputs:
        \\          out_b:
        \\            datasource: memory
        \\      - id: join
        \\        uses: mod/join
        \\        inputs:
        \\          a: out_a
        \\          b: out_b
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});

    var mod_reg = flowdata.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    var ambient = flowdata.AmbientContext.init(alloc);

    var reg = routing.RouterRegistry.init(alloc);
    defer reg.deinit();
    try reg.register("directed", &routing.DirectedRouter.factory);

    const strategy = try reg.createForMode(.directed, .{
        .allocator = alloc,
        .ast = ast,
        .pipeline = ast.getPipeline("diamond").?,
        .modules = &mod_reg,
        .ambient = &ambient,
    });
    defer strategy.deinit();

    const Dummy = struct { v: u32 };
    const in_val = Dummy{ .v = 1 };
    const out_a_val = Dummy{ .v = 10 };
    const out_b_val = Dummy{ .v = 20 };

    const p_in = flowdata.dataflow.PayloadHandle.fromScalar(Dummy, &in_val);
    const p_a = flowdata.dataflow.PayloadHandle.fromScalar(Dummy, &out_a_val);
    const p_b = flowdata.dataflow.PayloadHandle.fromScalar(Dummy, &out_b_val);

    // 1. Start activates only root (node 0)
    const start_acts = try strategy.onPipelineStart(alloc, p_in);
    try testing.expectEqual(@as(usize, 1), start_acts.len);
    try testing.expectEqual(@as(routing.NodeId, 0), start_acts[0].node_id);
    try testing.expect(strategy.hasPendingWork());

    // 2. Completing root unlocks both branch_a (1) and branch_b (2)
    const fork_acts = try strategy.onStepComplete(alloc, .{
        .node_id = 0,
        .status = .ok,
        .output = p_in,
    });
    try testing.expectEqual(@as(usize, 2), fork_acts.len);
    try testing.expectEqual(@as(routing.NodeId, 1), fork_acts[0].node_id);
    try testing.expectEqual(@as(routing.NodeId, 2), fork_acts[1].node_id);

    // 3. Completing branch_a alone must NOT unlock join (node 3) yet
    const after_a = try strategy.onStepComplete(alloc, .{
        .node_id = 1,
        .status = .ok,
        .output = p_a,
    });
    try testing.expectEqual(@as(usize, 0), after_a.len);
    try testing.expect(strategy.hasPendingWork());

    // 4. Completing branch_b unlocks join (node 3) with both `a` and `b` bound
    const after_b = try strategy.onStepComplete(alloc, .{
        .node_id = 2,
        .status = .ok,
        .output = p_b,
    });
    try testing.expectEqual(@as(usize, 1), after_b.len);
    try testing.expectEqual(@as(routing.NodeId, 3), after_b[0].node_id);
    try testing.expectEqual(@as(usize, 2), after_b[0].consumed_channels.len);

    var found_a = false;
    var found_b = false;
    for (after_b[0].bound_inputs) |bi| {
        if (std.mem.eql(u8, bi.name, "a")) {
            try testing.expectEqual(@as(u32, 10), bi.payload.asScalar(Dummy).v);
            found_a = true;
        } else if (std.mem.eql(u8, bi.name, "b")) {
            try testing.expectEqual(@as(u32, 20), bi.payload.asScalar(Dummy).v);
            found_b = true;
        }
    }
    try testing.expect(found_a and found_b);

    // 5. Completing join finishes pipeline
    const after_join = try strategy.onStepComplete(alloc, .{
        .node_id = 3,
        .status = .ok,
        .output = p_b,
    });
    try testing.expectEqual(@as(usize, 0), after_join.len);
    try testing.expect(!strategy.hasPendingWork());
}

test "ARCH-023 Phase 3: DirectedRouter handles unary where: short-circuit and fatal_error halt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\pipelines:
        \\  filtered:
        \\    steps:
        \\      - id: guard
        \\        uses: mod/guard
        \\        inputs:
        \\          input:
        \\            from: stream
        \\            where: "enabled == true"
        \\        outputs:
        \\          g_out:
        \\            datasource: memory
        \\      - id: next
        \\        uses: mod/next
        \\        inputs:
        \\          input: g_out
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    var mod_reg = flowdata.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    var ambient = flowdata.AmbientContext.init(alloc);

    const strategy = try routing.DirectedRouter.factory(.{
        .allocator = alloc,
        .ast = ast,
        .pipeline = ast.getPipeline("filtered").?,
        .modules = &mod_reg,
        .ambient = &ambient,
    });
    defer strategy.deinit();

    const Job = struct { enabled: bool };
    const disabled = Job{ .enabled = false };
    const p_disabled = flowdata.dataflow.PayloadHandle.fromScalar(Job, &disabled);

    // guard short-circuits (`enabled == false`), unlocking `next` immediately
    const acts = try strategy.onPipelineStart(alloc, p_disabled);
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expectEqual(@as(routing.NodeId, 1), acts[0].node_id);

    // Fatal error halts remaining work cleanly
    const after_err = try strategy.onStepComplete(alloc, .{
        .node_id = 1,
        .status = .fatal_error,
        .output = flowdata.dataflow.PayloadHandle.empty(),
    });
    try testing.expectEqual(@as(usize, 0), after_err.len);
    try testing.expect(!strategy.hasPendingWork());
}

test "ARCH-023 Phase 4: TypeDrivenRouter routes by signature and outbound loop without WorkerPool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const RawTarget = struct { video_id: []const u8 };
    const ProblemOut = struct { video_id: []const u8, is_problematic: bool };
    const CleanOut = struct { video_id: []const u8, is_clean: bool };

    const TriageSvc = struct {
        pub fn execute(_: *@This(), _: std.mem.Allocator, in: RawTarget) !ProblemOut {
            return .{ .video_id = in.video_id, .is_problematic = true };
        }
    };
    const CdrSvc = struct {
        pub fn canHandle(_: *@This(), payload: plugin.PayloadHandle_ABI) bool {
            if (payload.getReflected("is_problematic")) |v| {
                return v.asBool() orelse false;
            }
            return false;
        }
        pub fn execute(_: *@This(), _: std.mem.Allocator, in: ProblemOut) !CleanOut {
            return .{ .video_id = in.video_id, .is_clean = true };
        }
    };
    const IrSvc = struct {
        pub fn canHandle(_: *@This(), payload: plugin.PayloadHandle_ABI) bool {
            if (payload.getReflected("is_clean")) |v| {
                return v.asBool() orelse false;
            }
            return false;
        }
        pub fn execute(_: *@This(), _: std.mem.Allocator, in: CleanOut) !CleanOut {
            return in;
        }
    };

    var tasks = [_]plugin.TaskDescriptor_ABI{
        plugin.defineTaskService(TriageSvc, .{ .name = "triage" }),
        plugin.defineTaskService(CdrSvc, .{ .name = "cdr" }),
        plugin.defineTaskService(IrSvc, .{ .name = "ir" }),
    };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "td_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("td_test", &manifest);

    const yaml_text =
        \\version: 2
        \\pipelines:
        \\  mesh:
        \\    routing: type_driven
        \\    steps:
        \\      - id: s_triage
        \\        uses: td_test/triage
        \\      - id: s_cdr
        \\        uses: td_test/cdr
        \\      - id: s_ir
        \\        uses: td_test/ir
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    var ambient = flowdata.AmbientContext.init(alloc);

    var reg = routing.RouterRegistry.init(alloc);
    defer reg.deinit();
    try reg.register("type_driven", &routing.TypeDrivenRouter.factory);

    const strategy = try reg.createForMode(.type_driven, .{
        .allocator = alloc,
        .ast = ast,
        .pipeline = ast.getPipeline("mesh").?,
        .modules = &mod_reg,
        .ambient = &ambient,
    });
    defer strategy.deinit();

    // 1. Initial RawTarget matches only s_triage (node 0)
    const raw = RawTarget{ .video_id = "vid-1" };
    const p_raw = flowdata.dataflow.PayloadHandle.fromScalar(RawTarget, &raw);
    const start_acts = try strategy.onPipelineStart(alloc, p_raw);
    try testing.expectEqual(@as(usize, 1), start_acts.len);
    try testing.expectEqual(@as(routing.NodeId, 0), start_acts[0].node_id);

    // 2. Output ProblemOut(is_problematic=true) matches s_cdr (node 1)
    const prob = ProblemOut{ .video_id = "vid-1", .is_problematic = true };
    const p_prob = flowdata.dataflow.PayloadHandle.fromScalar(ProblemOut, &prob);
    const after_triage = try strategy.onStepComplete(alloc, .{
        .node_id = 0,
        .status = .ok,
        .output = p_prob,
    });
    try testing.expectEqual(@as(usize, 1), after_triage.len);
    try testing.expectEqual(@as(routing.NodeId, 1), after_triage[0].node_id);

    // 3. Output CleanOut(is_clean=true) matches s_ir (node 2)
    const clean = CleanOut{ .video_id = "vid-1", .is_clean = true };
    const p_clean = flowdata.dataflow.PayloadHandle.fromScalar(CleanOut, &clean);
    const after_cdr = try strategy.onStepComplete(alloc, .{
        .node_id = 1,
        .status = .ok,
        .output = p_clean,
    });
    try testing.expectEqual(@as(usize, 1), after_cdr.len);
    try testing.expectEqual(@as(routing.NodeId, 2), after_cdr[0].node_id);

    // 4. Completing s_ir finishes with no further activations (visited_mask prevents loop)
    const after_ir = try strategy.onStepComplete(alloc, .{
        .node_id = 2,
        .status = .ok,
        .output = p_clean,
    });
    try testing.expectEqual(@as(usize, 0), after_ir.len);
    try testing.expect(!strategy.hasPendingWork());
}

test "ARCH-023 Phase 4: TypeDrivenRouter respects ambient unary where: filters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Job = struct { task_id: []const u8 };
    const Svc = struct {
        pub fn execute(_: *@This(), _: std.mem.Allocator, in: Job) !Job {
            return in;
        }
    };

    var tasks = [_]plugin.TaskDescriptor_ABI{
        plugin.defineTaskService(Svc, .{ .name = "cpu_task" }),
    };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "td_unary",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("td_unary", &manifest);

    const yaml_text =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    routing: type_driven
        \\    steps:
        \\      - id: heavy
        \\        uses: td_unary/cpu_task
        \\        inputs:
        \\          cpu_usage:
        \\            from: system.cpu_load
        \\            where: "< 80"
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    const job = Job{ .task_id = "j1" };
    const p_job = flowdata.dataflow.PayloadHandle.fromScalar(Job, &job);

    // High CPU load -> rejected
    const amb_high = flowdata.AmbientContext.withValues(alloc, 1000, 10, 92.0);
    const r_high = try routing.TypeDrivenRouter.factory(.{
        .allocator = alloc,
        .ast = ast,
        .pipeline = ast.getPipeline("main").?,
        .modules = &mod_reg,
        .ambient = &amb_high,
    });
    defer r_high.deinit();
    const acts_high = try r_high.onPipelineStart(alloc, p_job);
    try testing.expectEqual(@as(usize, 0), acts_high.len);

    // Low CPU load -> accepted
    const amb_low = flowdata.AmbientContext.withValues(alloc, 1000, 10, 40.0);
    const r_low = try routing.TypeDrivenRouter.factory(.{
        .allocator = alloc,
        .ast = ast,
        .pipeline = ast.getPipeline("main").?,
        .modules = &mod_reg,
        .ambient = &amb_low,
    });
    defer r_low.deinit();
    const acts_low = try r_low.onPipelineStart(alloc, p_job);
    try testing.expectEqual(@as(usize, 1), acts_low.len);
}

test "ARCH-023 Phase 5: Coordinator with MockRouter verifies freeArena, backpressure, and cancellation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Item = struct { id: u32 };
    const ProdSvc = struct {
        pub const Context = struct {
            pub const concurrency_safe = true;
        };
        pub fn execute(_: *@This(), a: std.mem.Allocator) ![]const Item {
            const out = try a.alloc(Item, 4);
            for (out, 0..) |*it, i| it.* = .{ .id = @intCast(i + 1) };
            return out;
        }
    };
    const ConsSvc = struct {
        pub const Context = struct {
            pub const concurrency_safe = true;
        };
        pub fn execute(_: *@This(), _: std.mem.Allocator, in: Item) !Item {
            return .{ .id = in.id * 10 };
        }
    };
    const FailSvc = struct {
        pub fn execute(_: *@This(), _: std.mem.Allocator, _: Item) !Item {
            return error.SimulatedFailure;
        }
    };

    var tasks = [_]plugin.TaskDescriptor_ABI{
        plugin.defineTaskService(ProdSvc, .{ .name = "prod" }),
        plugin.defineTaskService(ConsSvc, .{ .name = "cons" }),
        plugin.defineTaskService(FailSvc, .{ .name = "fail" }),
    };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "coord_mock",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("coord_mock", &manifest);

    var repo_reg = flowdata.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const yaml_text =
        \\version: 2
        \\runtime:
        \\  scheduler: dag
        \\  workers: 2
        \\  max_inflight_bytes: 1B
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: s_prod1
        \\        uses: coord_mock/prod
        \\      - id: s_cons1
        \\        uses: coord_mock/cons
        \\        inputs:
        \\          primary: s_prod1
        \\      - id: s_prod2
        \\        uses: coord_mock/prod
        \\        inputs:
        \\          primary: stream
        \\        outputs:
        \\          - name: ch2
        \\            to: dummy_mem
    ;

    const parsed_ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    const pipe = parsed_ast.getPipeline("main").?;
    var exec_plan = try flowdata.engine.compilePlan(alloc, pipe, parsed_ast);
    defer exec_plan.deinit();

    var eng = flowdata.PipelineEngine.init(alloc, parsed_ast, &mod_reg, &repo_reg);
    defer eng.deinit();
    for (parsed_ast.datasources) |ds| {
        _ = try repo_reg.resolveOrCreate(ds);
    }

    var net_ctrl = try flowdata.engine.EngineNetworkController.init(alloc, parsed_ast, null);
    defer net_ctrl.deinit();

    var pool = try flowdata.concurrency.WorkerPool.init(alloc, 2);
    defer pool.deinit();

    const input_items = [_]Item{.{ .id = 1 }};
    const input_payload = flowdata.dataflow.PayloadHandle.fromSlice(Item, &input_items);

    const CoordMockRouter = struct {
        plan: *const flowdata.engine.ExecutionPlan,
        initial_payload: flowdata.dataflow.PayloadHandle,
        step: usize = 0,
        pending: usize = 0,

        pub fn onPipelineStart(self: *@This(), a: std.mem.Allocator, initial_input: flowdata.dataflow.PayloadHandle) ![]routing.TaskActivation {
            self.pending += 1;
            const res = try a.alloc(routing.TaskActivation, 1);
            res[0] = .{
                .node_id = 0,
                .step_input = initial_input,
                .consumed_channels = self.plan.nodes[0].consumed_channels,
            };
            return res;
        }

        pub fn onStepComplete(self: *@This(), a: std.mem.Allocator, event: routing.StepOutcomeEvent) ![]routing.TaskActivation {
            if (self.pending > 0) self.pending -= 1;
            if (event.status == .fatal_error) return &.{};
            if (event.node_id == 0 and self.step == 0) {
                self.step = 1;
                self.pending += 2;
                const res = try a.alloc(routing.TaskActivation, 2);
                res[0] = .{
                    .node_id = 1,
                    .step_input = event.output,
                    .consumed_channels = self.plan.nodes[1].consumed_channels,
                };
                res[1] = .{
                    .node_id = 2,
                    .step_input = self.initial_payload,
                    .consumed_channels = self.plan.nodes[2].consumed_channels,
                };
                return res;
            }
            return &.{};
        }

        pub fn hasPendingWork(self: *const @This()) bool {
            return self.pending > 0;
        }

        pub fn deinit(_: *@This()) void {}
    };

    var mock = CoordMockRouter{
        .plan = &exec_plan,
        .initial_payload = input_payload,
    };
    const strategy = routing.RoutingStrategy.fromImpl(CoordMockRouter, &mock);

    var outputs: std.StringHashMapUnmanaged(flowdata.dataflow.PayloadHandle) = .empty;
    var summary = flowdata.engine.ExecutionSummary{};
    const trace_id: [16]u8 = [_]u8{1} ** 16;
    const span_id: [8]u8 = [_]u8{2} ** 8;

    try flowdata.engine.Coordinator.runWithStrategy(
        &eng,
        &exec_plan,
        strategy,
        input_payload,
        &outputs,
        alloc,
        &net_ctrl,
        &summary,
        trace_id,
        span_id,
        pool,
    );

    try testing.expectEqual(@as(usize, 3), summary.steps_executed);
    try testing.expect(summary.arenas_created >= 3);
    try testing.expect(summary.arenas_freed_early >= 1);
    try testing.expect(summary.throttle_count >= 1);

    // Cancellation sub-case: fatal_error aborts cleanly
    const fail_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: s_fail
        \\        uses: coord_mock/fail
        \\      - id: s_after
        \\        uses: coord_mock/cons
    ;
    const fail_ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, fail_yaml, .{});
    const fail_pipe = fail_ast.getPipeline("main").?;
    var fail_plan = try flowdata.engine.compilePlan(alloc, fail_pipe, fail_ast);
    defer fail_plan.deinit();

    var fail_eng = flowdata.PipelineEngine.init(alloc, fail_ast, &mod_reg, &repo_reg);
    defer fail_eng.deinit();
    var fail_net = try flowdata.engine.EngineNetworkController.init(alloc, fail_ast, null);
    defer fail_net.deinit();

    const FailMockRouter = struct {
        pending: usize = 0,
        pub fn onPipelineStart(self: *@This(), a: std.mem.Allocator, initial_input: flowdata.dataflow.PayloadHandle) ![]routing.TaskActivation {
            self.pending = 1;
            const res = try a.alloc(routing.TaskActivation, 1);
            res[0] = .{ .node_id = 0, .step_input = initial_input };
            return res;
        }
        pub fn onStepComplete(self: *@This(), _: std.mem.Allocator, _: routing.StepOutcomeEvent) ![]routing.TaskActivation {
            if (self.pending > 0) self.pending -= 1;
            return &.{};
        }
        pub fn hasPendingWork(self: *const @This()) bool {
            return self.pending > 0;
        }
        pub fn deinit(_: *@This()) void {}
    };

    var fail_mock = FailMockRouter{};
    var fail_outputs: std.StringHashMapUnmanaged(flowdata.dataflow.PayloadHandle) = .empty;
    var fail_summary = flowdata.engine.ExecutionSummary{};
    const err = flowdata.engine.Coordinator.runWithStrategy(
        &fail_eng,
        &fail_plan,
        routing.RoutingStrategy.fromImpl(FailMockRouter, &fail_mock),
        input_payload,
        &fail_outputs,
        alloc,
        &fail_net,
        &fail_summary,
        trace_id,
        span_id,
        null,
    );
    try testing.expectError(error.TaskExecutionFailed, err);
    try testing.expectEqual(@as(usize, 0), fail_summary.steps_executed);
}

test "ARCH-023 Phase 5: PipelineEngine executes type_driven pipeline end-to-end via RouterRegistry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const RawTarget = struct { video_id: []const u8 };
    const ProblemOut = struct { video_id: []const u8, is_problematic: bool };
    const CleanOut = struct { video_id: []const u8, is_clean: bool };

    const TriageSvc = struct {
        pub fn execute(_: *@This(), _: std.mem.Allocator, in: RawTarget) !ProblemOut {
            return .{ .video_id = in.video_id, .is_problematic = true };
        }
    };
    const CdrSvc = struct {
        pub fn canHandle(_: *@This(), payload: plugin.PayloadHandle_ABI) bool {
            if (payload.getReflected("is_problematic")) |v| {
                return v.asBool() orelse false;
            }
            return false;
        }
        pub fn execute(_: *@This(), _: std.mem.Allocator, in: ProblemOut) !CleanOut {
            return .{ .video_id = in.video_id, .is_clean = true };
        }
    };

    var tasks = [_]plugin.TaskDescriptor_ABI{
        plugin.defineTaskService(TriageSvc, .{ .name = "triage" }),
        plugin.defineTaskService(CdrSvc, .{ .name = "cdr" }),
    };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "e2e_td",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("e2e_td", &manifest);

    var repo_reg = flowdata.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const yaml_text =
        \\version: 2
        \\runtime:
        \\  scheduler: dag
        \\  workers: 2
        \\  routing: type_driven
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: s_triage
        \\        uses: e2e_td/triage
        \\      - id: s_cdr
        \\        uses: e2e_td/cdr
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    var eng = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer eng.deinit();

    const raw = [_]RawTarget{.{ .video_id = "vid-e2e" }};
    const summary = try eng.run(flowdata.dataflow.PayloadHandle.fromSlice(RawTarget, &raw));
    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
}
