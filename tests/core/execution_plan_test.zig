//! Unit and integration tests for ARCH-017 Phase 17.2:
//! ExecutionPlan Compiler, DAG Dependency Resolution, and Topological Validation.

const std = @import("std");
const testing = std.testing;
const flowdata = @import("flowdata");
const plugin = @import("flowdata_plugin");

test "ExecutionPlan: Diamond DAG (Fan-out / Fan-in) with correct topological order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_a
        \\        uses: core/noop
        \\        outputs:
        \\          batch:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_b
        \\        uses: core/noop
        \\        inputs:
        \\          in_batch: step_a.batch
        \\        outputs:
        \\          left_res:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_c
        \\        uses: core/noop
        \\        inputs:
        \\          in_batch: step_a.batch
        \\        outputs:
        \\          right_res:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_d
        \\        uses: core/noop
        \\        inputs:
        \\          left: step_b.left_res
        \\          right: step_c.right_res
        \\        outputs:
        \\          joined:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    const main_pipe = ast.getPipeline("main").?;

    var plan = try flowdata.engine.compilePlan(alloc, main_pipe, ast);
    defer plan.deinit();

    // 1. Verify Node and Channel counts
    try testing.expectEqual(@as(usize, 4), plan.nodes.len);
    try testing.expectEqual(@as(usize, 4), plan.channels.len);

    // 2. Verify Node indices
    const node_a = plan.findNodeByStepId("step_a").?;
    const node_b = plan.findNodeByStepId("step_b").?;
    const node_c = plan.findNodeByStepId("step_c").?;
    const node_d = plan.findNodeByStepId("step_d").?;

    try testing.expectEqual(@as(usize, 0), plan.nodes[node_a].indegree);
    try testing.expectEqual(@as(usize, 1), plan.nodes[node_b].indegree);
    try testing.expectEqual(@as(usize, 1), plan.nodes[node_c].indegree);
    try testing.expectEqual(@as(usize, 2), plan.nodes[node_d].indegree);

    // 3. Verify Successors and Predecessors
    try testing.expectEqual(@as(usize, 2), plan.nodes[node_a].successors.len);
    try testing.expectEqual(@as(usize, 2), plan.nodes[node_d].predecessors.len);

    // 4. Verify Topological Order
    try testing.expectEqual(@as(usize, 4), plan.topological_order.len);
    // Node A must be first
    try testing.expectEqual(node_a, plan.topological_order[0]);
    // Node D must be last
    try testing.expectEqual(node_d, plan.topological_order[3]);
    // Nodes B and C must be in the middle (before D)
    const pos_b = std.mem.indexOfScalar(usize, plan.topological_order, node_b).?;
    const pos_c = std.mem.indexOfScalar(usize, plan.topological_order, node_c).?;
    try testing.expect(pos_b < 3 and pos_b > 0);
    try testing.expect(pos_c < 3 and pos_c > 0);
}

test "ExecutionPlan: Explicit after dependency creates ordering edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_first
        \\        uses: core/noop
        \\
        \\      - id: step_second
        \\        uses: core/noop
        \\        after: [step_first]
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    const main_pipe = ast.getPipeline("main").?;

    var plan = try flowdata.engine.compilePlan(alloc, main_pipe, ast);
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 2), plan.nodes.len);
    try testing.expectEqual(@as(usize, 1), plan.edges.len);
    try testing.expectEqual(flowdata.engine.plan.EdgeKind.ordering, plan.edges[0].kind);

    try testing.expectEqual(@as(usize, 0), plan.topological_order[0]);
    try testing.expectEqual(@as(usize, 1), plan.topological_order[1]);
}

test "ExecutionPlan: Serializes writes to same non-memory datasource in declaration order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\datasources:
        \\  db_store:
        \\    driver: sqlite
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_write1
        \\        uses: core/noop
        \\        outputs:
        \\          out1:
        \\            datasource: db_store
        \\
        \\      - id: step_mem
        \\        uses: core/noop
        \\        outputs:
        \\          mem_out:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_write2
        \\        uses: core/noop
        \\        outputs:
        \\          out2:
        \\            datasource: db_store
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    const main_pipe = ast.getPipeline("main").?;

    var plan = try flowdata.engine.compilePlan(alloc, main_pipe, ast);
    defer plan.deinit();

    const node_w1 = plan.findNodeByStepId("step_write1").?;
    const node_w2 = plan.findNodeByStepId("step_write2").?;

    // There must be an ordering edge from step_write1 to step_write2
    var found_ordering_edge = false;
    for (plan.edges) |e| {
        if (e.from == node_w1 and e.to == node_w2 and e.kind == .ordering) {
            found_ordering_edge = true;
            break;
        }
    }
    try testing.expect(found_ordering_edge);
}

test "ExecutionPlan: Load-time single-writer violation error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: producer_1
        \\        uses: core/noop
        \\        outputs:
        \\          shared_channel:
        \\            datasource: pipeline_memory
        \\
        \\      - id: producer_2
        \\        uses: core/noop
        \\        outputs:
        \\          shared_channel:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    const main_pipe = ast.getPipeline("main").?;

    try testing.expectError(error.SingleWriterViolation, flowdata.engine.compilePlan(alloc, main_pipe, ast));
}

test "ExecutionPlan: Load-time cycle detection with CycleDetected error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_a
        \\        uses: core/noop
        \\        after: [step_b]
        \\
        \\      - id: step_b
        \\        uses: core/noop
        \\        after: [step_a]
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    const main_pipe = ast.getPipeline("main").?;

    try testing.expectError(error.CycleDetected, flowdata.engine.compilePlan(alloc, main_pipe, ast));
}

test "ExecutionPlan: Router barrier serializes subsequent steps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: prep_step
        \\        uses: core/noop
        \\
        \\      - router: check_condition
        \\        cases:
        \\          - when: "true"
        \\            goto: continue
        \\
        \\      - id: after_router_step
        \\        uses: core/noop
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    const main_pipe = ast.getPipeline("main").?;

    var plan = try flowdata.engine.compilePlan(alloc, main_pipe, ast);
    defer plan.deinit();

    const router_idx = plan.findNodeByStepId("check_condition").?;
    const after_idx = plan.findNodeByStepId("after_router_step").?;

    var found_barrier_edge = false;
    for (plan.edges) |e| {
        if (e.from == router_idx and e.to == after_idx and e.kind == .router_barrier) {
            found_barrier_edge = true;
            break;
        }
    }
    try testing.expect(found_barrier_edge);
}

const SampleOut = struct {
    num: u64,
};

const ProducerTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *ProducerTask, alloc: std.mem.Allocator) ![]const SampleOut {
        const slice = try alloc.alloc(SampleOut, 1);
        slice[0] = .{ .num = 777 };
        return slice;
    }
};

const ConsumerTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *ConsumerTask, item: SampleOut) !SampleOut {
        return .{ .num = item.num + 1 };
    }
};

test "ExecutionPlan: Reorders declared steps by topological order at runtime" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prod_desc = plugin.defineTaskService(ProducerTask, .{
        .name = "produce_num",
    });
    const cons_desc = plugin.defineTaskService(ConsumerTask, .{
        .name = "consume_num",
        .lift = .elemental,
    });

    var tasks = [_]plugin.TaskDescriptor_ABI{ prod_desc, cons_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "reorder_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("reorder_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    // NOTE: Declared IN REVERSE ORDER!
    // step_consumer is written BEFORE step_producer in YAML.
    // The ExecutionPlan compiler must topologically sort step_producer first!
    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_consumer
        \\        uses: reorder_demo/consume_num
        \\        inputs:
        \\          num_in: step_producer.number
        \\        outputs:
        \\          final_result:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_producer
        \\        uses: reorder_demo/produce_num
        \\        outputs:
        \\          number:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());
    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
    try testing.expect(!summary.halted_early);

    const out_repo = repo_reg.get("pipeline_memory").?;
    const payload = out_repo.readPayload("final_result").?;
    const slice = payload.asSlice(SampleOut);
    try testing.expectEqual(@as(usize, 1), slice.len);
    try testing.expectEqual(@as(u64, 778), slice[0].num);
}
