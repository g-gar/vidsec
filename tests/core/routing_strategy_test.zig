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
