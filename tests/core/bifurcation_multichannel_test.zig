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

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

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
    defer engine.deinit();
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

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

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
    defer engine.deinit();
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

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

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
    defer engine.deinit();
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());

    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
}

const ParallelNum = struct {
    id: u64,
    val: u64,
};

const ParallelOut = struct {
    id: u64,
    doubled: u64,
};

const ParallelProducer = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *ParallelProducer, alloc: std.mem.Allocator) ![]const ParallelNum {
        const items = try alloc.alloc(ParallelNum, 100);
        for (0..100) |i| {
            items[i] = .{ .id = i, .val = i * 10 };
        }
        return items;
    }
};

const ParallelMapper = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *ParallelMapper, item: ParallelNum) !ParallelOut {
        return .{
            .id = item.id,
            .doubled = item.val * 2,
        };
    }
};

test "ARCH-016 Phase 16.5: Parallel intra-step elemental lifting with 4 worker pool and helpWhile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prod_desc = plugin.defineTaskService(ParallelProducer, .{
        .name = "produce_stream",
    });
    const map_desc = plugin.defineTaskService(ParallelMapper, .{
        .name = "map_parallel",
        .lift = .elemental,
    });

    var tasks = [_]plugin.TaskDescriptor_ABI{ prod_desc, map_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "parallel_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("parallel_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  workers: 4
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_prod
        \\        uses: parallel_demo/produce_stream
        \\        outputs:
        \\          stream_data:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_map
        \\        uses: parallel_demo/map_parallel
        \\        concurrency: 4
        \\        inputs:
        \\          primary: stream_data
        \\        outputs:
        \\          results:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());

    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
    try testing.expect(!summary.halted_early);

    // Verify results from repository
    const out_repo = repo_reg.get("pipeline_memory").?;
    const payload = out_repo.readPayload("results").?;
    try testing.expectEqual(@as(usize, 100), payload.len);
    try testing.expect(payload.is_stream);

    const out_slice = payload.asSlice(ParallelOut);
    for (out_slice, 0..) |elem, i| {
        try testing.expectEqual(@as(u64, i), elem.id);
        try testing.expectEqual(@as(u64, i * 20), elem.doubled);
    }
}

const ParallelFilter = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *ParallelFilter, item: ParallelNum) !?ParallelOut {
        if (item.id % 2 == 0) {
            return ParallelOut{
                .id = item.id,
                .doubled = item.val * 2,
            };
        }
        return null;
    }
};

const Parallel50Producer = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *Parallel50Producer, alloc: std.mem.Allocator) ![]const ParallelNum {
        const items = try alloc.alloc(ParallelNum, 50);
        for (0..50) |i| {
            items[i] = .{ .id = i, .val = i * 10 };
        }
        return items;
    }
};

const ParallelExpander = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *ParallelExpander, alloc: std.mem.Allocator, item: ParallelNum) ![]const ParallelOut {
        var slice = try alloc.alloc(ParallelOut, 2);
        slice[0] = .{ .id = item.id * 2, .doubled = item.val };
        slice[1] = .{ .id = item.id * 2 + 1, .doubled = item.val + 1 };
        return slice;
    }
};

const ParallelFallibleMapper = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *ParallelFallibleMapper, item: ParallelNum) !ParallelOut {
        if (item.id == 13 or item.id == 42) {
            return error.InvalidData;
        }
        return .{
            .id = item.id,
            .doubled = item.val * 2,
        };
    }
};

test "ARCH-016 Phase 16.5: Parallel Filter (1 -> 0..1) with order preservation and compaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prod_desc = plugin.defineTaskService(ParallelProducer, .{
        .name = "produce_stream",
    });
    const filter_desc = plugin.defineTaskService(ParallelFilter, .{
        .name = "filter_parallel",
        .lift = .elemental,
    });

    var tasks = [_]plugin.TaskDescriptor_ABI{ prod_desc, filter_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "parallel_filter_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("parallel_filter_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  workers: 4
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_prod
        \\        uses: parallel_filter_demo/produce_stream
        \\        outputs:
        \\          stream_data:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_filter
        \\        uses: parallel_filter_demo/filter_parallel
        \\        concurrency: 4
        \\        inputs:
        \\          primary: stream_data
        \\        outputs:
        \\          results:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());

    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
    try testing.expect(!summary.halted_early);

    const out_repo = repo_reg.get("pipeline_memory").?;
    const payload = out_repo.readPayload("results").?;
    try testing.expectEqual(@as(usize, 50), payload.len);
    try testing.expect(payload.is_stream);

    const out_slice = payload.asSlice(ParallelOut);
    for (out_slice, 0..) |elem, i| {
        try testing.expectEqual(@as(u64, i * 2), elem.id);
        try testing.expectEqual(@as(u64, (i * 2) * 20), elem.doubled);
    }
}

test "ARCH-016 Phase 16.5: Parallel Expansion (1 -> M) with order preservation and flattening" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prod_desc = plugin.defineTaskService(Parallel50Producer, .{
        .name = "produce_50_stream",
    });
    const expand_desc = plugin.defineTaskService(ParallelExpander, .{
        .name = "expand_parallel",
        .lift = .elemental,
    });

    var tasks = [_]plugin.TaskDescriptor_ABI{ prod_desc, expand_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "parallel_expand_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("parallel_expand_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  workers: 4
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_prod
        \\        uses: parallel_expand_demo/produce_50_stream
        \\        outputs:
        \\          stream_data:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_expand
        \\        uses: parallel_expand_demo/expand_parallel
        \\        concurrency: 4
        \\        inputs:
        \\          primary: stream_data
        \\        outputs:
        \\          results:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());

    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
    try testing.expect(!summary.halted_early);

    const out_repo = repo_reg.get("pipeline_memory").?;
    const payload = out_repo.readPayload("results").?;
    try testing.expectEqual(@as(usize, 100), payload.len);
    try testing.expect(payload.is_stream);

    const out_slice = payload.asSlice(ParallelOut);
    for (out_slice, 0..) |elem, i| {
        try testing.expectEqual(@as(u64, i), elem.id);
    }
}

test "ARCH-016 Phase 16.5: Parallel elemental lifting with fail_fast error policy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prod_desc = plugin.defineTaskService(ParallelProducer, .{
        .name = "produce_stream",
    });
    const map_desc = plugin.defineTaskService(ParallelFallibleMapper, .{
        .name = "map_fallible",
        .lift = .elemental,
    });

    var tasks = [_]plugin.TaskDescriptor_ABI{ prod_desc, map_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "parallel_fail_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("parallel_fail_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  workers: 4
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_prod
        \\        uses: parallel_fail_demo/produce_stream
        \\        outputs:
        \\          stream_data:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_map
        \\        uses: parallel_fail_demo/map_fallible
        \\        concurrency: 4
        \\        inputs:
        \\          primary: stream_data
        \\        params:
        \\          on_item_error: "fail_fast"
        \\        outputs:
        \\          results:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();
    try testing.expectError(error.TaskExecutionFailed, engine.run(flowdata.dataflow.PayloadHandle.empty()));
}

test "ARCH-016 Phase 16.5: Parallel elemental lifting with skip error policy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prod_desc = plugin.defineTaskService(ParallelProducer, .{
        .name = "produce_stream",
    });
    const map_desc = plugin.defineTaskService(ParallelFallibleMapper, .{
        .name = "map_fallible",
        .lift = .elemental,
    });

    var tasks = [_]plugin.TaskDescriptor_ABI{ prod_desc, map_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "parallel_skip_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("parallel_skip_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  workers: 4
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_prod
        \\        uses: parallel_skip_demo/produce_stream
        \\        outputs:
        \\          stream_data:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_map
        \\        uses: parallel_skip_demo/map_fallible
        \\        concurrency: 4
        \\        inputs:
        \\          primary: stream_data
        \\        params:
        \\          on_item_error: "skip"
        \\        outputs:
        \\          results:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());

    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
    try testing.expect(!summary.halted_early);

    const out_repo = repo_reg.get("pipeline_memory").?;
    const payload = out_repo.readPayload("results").?;
    // 100 items - 2 skipped (13 and 42) = 98 items
    try testing.expectEqual(@as(usize, 98), payload.len);
    try testing.expect(payload.is_stream);

    const out_slice = payload.asSlice(ParallelOut);
    var expected_id: u64 = 0;
    for (out_slice) |elem| {
        if (expected_id == 13 or expected_id == 42) expected_id += 1;
        try testing.expectEqual(expected_id, elem.id);
        try testing.expectEqual(expected_id * 20, elem.doubled);
        expected_id += 1;
    }
}

test "ARCH-016 Phase 16.5: Parallel elemental lifting with collect error policy and errors channel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prod_desc = plugin.defineTaskService(ParallelProducer, .{
        .name = "produce_stream",
    });
    const map_desc = plugin.defineTaskService(ParallelFallibleMapper, .{
        .name = "map_fallible",
        .lift = .elemental,
    });

    var tasks = [_]plugin.TaskDescriptor_ABI{ prod_desc, map_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "parallel_collect_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("parallel_collect_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  workers: 4
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_prod
        \\        uses: parallel_collect_demo/produce_stream
        \\        outputs:
        \\          stream_data:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_map
        \\        uses: parallel_collect_demo/map_fallible
        \\        concurrency: 4
        \\        inputs:
        \\          primary: stream_data
        \\        params:
        \\          on_item_error: "collect"
        \\        outputs:
        \\          results:
        \\            datasource: pipeline_memory
        \\          errors:
        \\            datasource: pipeline_memory
        \\            from: errors
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());

    try testing.expectEqual(@as(usize, 2), summary.steps_executed);
    try testing.expect(!summary.halted_early);

    const out_repo = repo_reg.get("pipeline_memory").?;

    // 1. Verify primary results
    const payload = out_repo.readPayload("results").?;
    try testing.expectEqual(@as(usize, 98), payload.len);
    try testing.expect(payload.is_stream);

    const out_slice = payload.asSlice(ParallelOut);
    var expected_id: u64 = 0;
    for (out_slice) |elem| {
        if (expected_id == 13 or expected_id == 42) expected_id += 1;
        try testing.expectEqual(expected_id, elem.id);
        try testing.expectEqual(expected_id * 20, elem.doubled);
        expected_id += 1;
    }

    // 2. Verify errors channel
    const err_payload = out_repo.readPayload("errors").?;
    try testing.expectEqual(@as(usize, 2), err_payload.len);
    try testing.expect(err_payload.is_stream);

    const err_slice = err_payload.asSlice(plugin.ItemError);
    try testing.expectEqual(@as(u64, 13), err_slice[0].index);
    try testing.expectEqualStrings("InvalidData", err_slice[0].error_name);

    try testing.expectEqual(@as(u64, 42), err_slice[1].index);
    try testing.expectEqualStrings("InvalidData", err_slice[1].error_name);
}
