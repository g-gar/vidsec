//! Pluggable RoutingStrategy & RouterRegistry Tests (ARCH-023 Phase 2).
//!
//! Validates the decoupled RoutingStrategy vtable contract and RouterRegistry
//! using a pure in-memory MockRouter with zero WorkerPool, network, or I/O.

const std = @import("std");
const testing = std.testing;
const flowdata = @import("flowdata");
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
