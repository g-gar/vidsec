const std = @import("std");
const testing = std.testing;
const flowdata = @import("flowdata");
const plugin = @import("flowdata_plugin");
const dataflow = @import("flowdata_dataflow");

const Lowered = plugin.Lowered;
const lowerValue = plugin.lowerValue;
const liftValue = plugin.liftValue;
const schemaId = plugin.schemaId;

const SampleItem = struct {
    id: u64,
    name: []const u8,
    active: bool,
    rating: f64,
};

test "ARCH-016: Lowered(T) and schemaId determinism" {
    _ = Lowered(SampleItem);
    const sid1 = schemaId(SampleItem);
    const sid2 = schemaId(SampleItem);

    try testing.expectEqual(sid1, sid2);

    const DifferentItem = struct {
        id: u64,
        name: []const u8,
        active: bool,
        rating: f32, // different float size
    };
    const sid_diff = schemaId(DifferentItem);
    try testing.expect(sid1 != sid_diff);

    // Test lowering and lifting
    const original = SampleItem{
        .id = 42,
        .name = "Flowdata",
        .active = true,
        .rating = 99.5,
    };

    const lowered = lowerValue(SampleItem, original);
    try testing.expectEqual(@as(u64, 42), lowered.id);
    try testing.expectEqualStrings("Flowdata", lowered.name.asSlice());
    try testing.expectEqual(@as(u8, 1), lowered.active);
    try testing.expectEqual(@as(f64, 99.5), lowered.rating);

    const lifted = liftValue(SampleItem, lowered);
    try testing.expectEqual(original.id, lifted.id);
    try testing.expectEqualStrings(original.name, lifted.name);
    try testing.expectEqual(original.active, lifted.active);
    try testing.expectEqual(original.rating, lifted.rating);
}

test "ARCH-016: Multi-channel Channels(T) wrapper" {
    const BatchResult = struct {
        items: []const SampleItem,
        count: u64,
    };

    const Wrapped = plugin.Channels(BatchResult);
    try testing.expect(Wrapped.is_flowdata_channels);

    const sample_items = [_]SampleItem{
        .{ .id = 1, .name = "a", .active = true, .rating = 1.0 },
        .{ .id = 2, .name = "b", .active = false, .rating = 2.0 },
    };

    const wrapped_val = plugin.channels(BatchResult{
        .items = &sample_items,
        .count = 2,
    });

    try testing.expectEqual(@as(u64, 2), wrapped_val.data.count);
    try testing.expectEqual(@as(usize, 2), wrapped_val.data.items.len);
}

const ProducerOutput = struct {
    items: []const SampleItem,
    summary: []const u8,
};

const ProducerService = struct {
    pub fn execute(_: *ProducerService, alloc: std.mem.Allocator) !plugin.Channels(ProducerOutput) {
        const items_slice = try alloc.alloc(SampleItem, 2);
        items_slice[0] = .{ .id = 101, .name = "alpha", .active = true, .rating = 5.0 };
        items_slice[1] = .{ .id = 102, .name = "beta", .active = false, .rating = 4.0 };

        return plugin.channels(ProducerOutput{
            .items = items_slice,
            .summary = "batch_ok",
        });
    }
};

const ConsumerInputs = struct {
    items: []const SampleItem,
    summary: []const u8,
};

const ConsumerService = struct {
    pub fn execute(_: *ConsumerService, _: std.mem.Allocator, inputs: ConsumerInputs) !u64 {
        return inputs.items.len;
    }
};

test "ARCH-016: End-to-End Multi-Channel emission and binding in PipelineEngine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const producer_desc = plugin.defineTaskService(ProducerService, .{
        .name = "produce_batch",
    });

    const consumer_desc = plugin.defineTaskService(ConsumerService, .{
        .name = "consume_batch",
    });

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    var demo_tasks = [_]plugin.TaskDescriptor_ABI{
        producer_desc,
        consumer_desc,
    };

    const demo_manifest = plugin.ModuleManifest_ABI{
        .module_name = "demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &demo_tasks,
        .tasks_len = demo_tasks.len,
    };

    try mod_reg.registerStaticModule("demo", &demo_manifest);

    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_producer
        \\        uses: demo/produce_batch
        \\        outputs:
        \\          items:
        \\            datasource: pipeline_memory
        \\          summary:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_consumer
        \\        uses: demo/consume_batch
        \\        inputs:
        \\          items: items
        \\          summary: summary
        \\        outputs:
        \\          final_count:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});

    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());

    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
}

const InputNumber = struct {
    val: i64,
};

const DoubledNumber = struct {
    val: i64,
};

const NumberProducerService = struct {
    pub fn execute(_: *NumberProducerService, alloc: std.mem.Allocator) ![]const InputNumber {
        const out = try alloc.alloc(InputNumber, 4);
        out[0] = .{ .val = 1 };
        out[1] = .{ .val = 2 };
        out[2] = .{ .val = 3 };
        out[3] = .{ .val = 4 };
        return out;
    }
};

const MapDoubleService = struct {
    pub fn execute(_: *MapDoubleService, _: std.mem.Allocator, item: InputNumber) !DoubledNumber {
        return .{ .val = item.val * 2 };
    }
};

const FilterEvenService = struct {
    pub fn execute(_: *FilterEvenService, _: std.mem.Allocator, item: InputNumber) !?DoubledNumber {
        if (@mod(item.val, 2) == 0) {
            return .{ .val = item.val };
        }
        return null;
    }
};

const ExpandPairService = struct {
    pub fn execute(_: *ExpandPairService, alloc: std.mem.Allocator, item: InputNumber) ![]const DoubledNumber {
        const out = try alloc.alloc(DoubledNumber, 2);
        out[0] = .{ .val = item.val };
        out[1] = .{ .val = item.val * 10 };
        return out;
    }
};

test "ARCH-016 Phase 16.4: Elemental Auto-Lifting (Map, Filter, Expansion)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const producer_desc = plugin.defineTaskService(NumberProducerService, .{
        .name = "produce_numbers",
    });

    const map_desc = plugin.defineTaskService(MapDoubleService, .{
        .name = "map_double",
        .lift = .elemental,
    });

    const filter_desc = plugin.defineTaskService(FilterEvenService, .{
        .name = "filter_evens",
        .lift = .elemental,
    });

    const expand_desc = plugin.defineTaskService(ExpandPairService, .{
        .name = "expand_pairs",
        .lift = .elemental,
    });

    var demo_tasks = [_]plugin.TaskDescriptor_ABI{
        producer_desc,
        map_desc,
        filter_desc,
        expand_desc,
    };

    const demo_manifest = plugin.ModuleManifest_ABI{
        .module_name = "math_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &demo_tasks,
        .tasks_len = demo_tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("math_demo", &demo_manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_producer
        \\        uses: math_demo/produce_numbers
        \\        outputs:
        \\          nums:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_map
        \\        uses: math_demo/map_double
        \\        inputs:
        \\          stream: nums
        \\        outputs:
        \\          doubled:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_filter
        \\        uses: math_demo/filter_evens
        \\        inputs:
        \\          stream: nums
        \\        outputs:
        \\          evens:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_expand
        \\        uses: math_demo/expand_pairs
        \\        inputs:
        \\          stream: evens
        \\        outputs:
        \\          expanded:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());

    try testing.expectEqual(@as(usize, 4), summary.steps_executed);
}

const CompositeElementalInputs = struct {
    item: InputNumber,
    multiplier: i64,
};

const MultiplierService = struct {
    pub fn execute(_: *MultiplierService, _: std.mem.Allocator, inputs: CompositeElementalInputs) !DoubledNumber {
        return .{ .val = inputs.item.val * inputs.multiplier };
    }
};

test "ARCH-016 Phase 16.4: Composite Elemental task with broadcast scalar input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const producer_desc = plugin.defineTaskService(NumberProducerService, .{
        .name = "produce_numbers",
    });

    const multiply_desc = plugin.defineTaskService(MultiplierService, .{
        .name = "multiply_numbers",
        .lift = .elemental,
    });

    var demo_tasks = [_]plugin.TaskDescriptor_ABI{
        producer_desc,
        multiply_desc,
    };

    const demo_manifest = plugin.ModuleManifest_ABI{
        .module_name = "composite_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &demo_tasks,
        .tasks_len = demo_tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("composite_demo", &demo_manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_producer
        \\        uses: composite_demo/produce_numbers
        \\        outputs:
        \\          nums:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_multiply
        \\        uses: composite_demo/multiply_numbers
        \\        inputs:
        \\          stream: nums
        \\        params:
        \\          multiplier: 5
        \\        outputs:
        \\          result:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());

    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
}

const RowsConsumerInputs = struct {
    nums: plugin.Rows(InputNumber),
};

const RowsSumService = struct {
    pub fn execute(_: *RowsSumService, _: std.mem.Allocator, inputs: RowsConsumerInputs) !i64 {
        var iter = inputs.nums;
        var sum: i64 = 0;
        while (iter.next()) |item| {
            sum += item.val;
        }
        return sum;
    }
};

test "ARCH-016 Phase 16.4: Lazy Rows(T) stream iterator injection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const producer_desc = plugin.defineTaskService(NumberProducerService, .{
        .name = "produce_numbers",
    });

    const sum_desc = plugin.defineTaskService(RowsSumService, .{
        .name = "sum_numbers",
    });

    var demo_tasks = [_]plugin.TaskDescriptor_ABI{
        producer_desc,
        sum_desc,
    };

    const demo_manifest = plugin.ModuleManifest_ABI{
        .module_name = "rows_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &demo_tasks,
        .tasks_len = demo_tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("rows_demo", &demo_manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_producer
        \\        uses: rows_demo/produce_numbers
        \\        outputs:
        \\          nums:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_sum
        \\        uses: rows_demo/sum_numbers
        \\        inputs:
        \\          nums: nums
        \\        outputs:
        \\          final_sum:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());

    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
}
