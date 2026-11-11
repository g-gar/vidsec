//! Flowdata Concurrent DAG Scheduler Tests (ARCH-017 Phase 17.3).
//!
//! Comprehensive verification suite:
//! 1. Concurrent Diamond DAG (True Concurrency across independent branches)
//! 2. Multi-Branch Fan-Out / Fan-In Concurrency (4 parallel branches on 4 workers)
//! 3. Concurrent Cancellation and Deterministic Error Handling
//! 4. Nested Parallelism (DAG Coordinator + Intra-Step Elemental Lifting on shared WorkerPool)
//! 5. Single-Worker DAG Fallback (workers: 1 sequential path)

const std = @import("std");
const testing = std.testing;
const flowdata = @import("flowdata");
const plugin = @import("flowdata_plugin");

pub const SampleItem = struct {
    id: u32,
    val: u64,
};

pub const FinalResult = struct {
    total: u64,
};

fn sleepMs(ms: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&ts, null);
}

// Global atomic concurrency tracker for tests
var global_concurrent_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var global_max_concurrent: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn recordEnter() u32 {
    const cur = global_concurrent_count.fetchAdd(1, .acq_rel) + 1;
    while (true) {
        const max_val = global_max_concurrent.load(.acquire);
        if (cur <= max_val) break;
        if (global_max_concurrent.cmpxchgWeak(max_val, cur, .acq_rel, .acquire) == null) break;
    }
    return cur;
}

fn recordExit() void {
    _ = global_concurrent_count.fetchSub(1, .acq_rel);
}

fn resetConcurrencyTracker() void {
    global_concurrent_count.store(0, .release);
    global_max_concurrent.store(0, .release);
}

// -------------------------------------------------------------------------
// Tasks for Test 1 & Test 5: Diamond DAG
// -------------------------------------------------------------------------

const DiamondRootTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *DiamondRootTask, alloc: std.mem.Allocator) ![]const SampleItem {
        const slice = try alloc.alloc(SampleItem, 1);
        slice[0] = .{ .id = 1, .val = 100 };
        return slice;
    }
};

const DiamondBranchInputs = struct {
    stream: []const SampleItem,
};

const DiamondBranchATask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *DiamondBranchATask, alloc: std.mem.Allocator, inputs: DiamondBranchInputs) ![]const SampleItem {
        _ = recordEnter();
        defer recordExit();

        sleepMs(35);

        const slice = try alloc.alloc(SampleItem, 1);
        slice[0] = .{ .id = 10, .val = inputs.stream[0].val + 10 };
        return slice;
    }
};

const DiamondBranchBTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *DiamondBranchBTask, alloc: std.mem.Allocator, inputs: DiamondBranchInputs) ![]const SampleItem {
        _ = recordEnter();
        defer recordExit();

        sleepMs(35);

        const slice = try alloc.alloc(SampleItem, 1);
        slice[0] = .{ .id = 20, .val = inputs.stream[0].val + 20 };
        return slice;
    }
};

const DiamondJoinInputs = struct {
    in_merged: []const SampleItem,
};

const DiamondJoinTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *DiamondJoinTask, alloc: std.mem.Allocator, inputs: DiamondJoinInputs) ![]const FinalResult {
        var sum: u64 = 0;
        for (inputs.in_merged) |item| {
            sum += item.val;
        }
        const slice = try alloc.alloc(FinalResult, 1);
        slice[0] = .{ .total = sum };
        return slice;
    }
};

test "ARCH-017 Phase 17.3: Concurrent Diamond DAG executes branches in parallel" {
    resetConcurrencyTracker();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root_desc = plugin.defineTaskService(DiamondRootTask, .{ .name = "diamond_root" });
    const branch_a_desc = plugin.defineTaskService(DiamondBranchATask, .{ .name = "branch_a" });
    const branch_b_desc = plugin.defineTaskService(DiamondBranchBTask, .{ .name = "branch_b" });
    const join_desc = plugin.defineTaskService(DiamondJoinTask, .{ .name = "diamond_join" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ root_desc, branch_a_desc, branch_b_desc, join_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "dag_diamond_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("dag_diamond_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  scheduler: dag
        \\  workers: 4
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: root
        \\        uses: dag_diamond_demo/diamond_root
        \\        outputs:
        \\          seed:
        \\            datasource: pipeline_memory
        \\
        \\      - id: left_branch
        \\        uses: dag_diamond_demo/branch_a
        \\        inputs:
        \\          stream: root.seed
        \\        outputs:
        \\          left_out:
        \\            datasource: pipeline_memory
        \\
        \\      - id: right_branch
        \\        uses: dag_diamond_demo/branch_b
        \\        inputs:
        \\          stream: root.seed
        \\        outputs:
        \\          right_out:
        \\            datasource: pipeline_memory
        \\
        \\      - id: join_step
        \\        uses: dag_diamond_demo/diamond_join
        \\        inputs:
        \\          in_merged: merge(left_branch.left_out, right_branch.right_out)
        \\        outputs:
        \\          joined:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    const start_time = flowdata.engine.nowNs();
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());
    const elapsed_ms = (flowdata.engine.nowNs() - start_time) / 1_000_000;

    try testing.expectEqual(@as(usize, 4), summary.steps_executed);
    try testing.expect(!summary.halted_early);

    // Both left_branch and right_branch ran concurrently!
    try testing.expect(global_max_concurrent.load(.acquire) >= 2);
    try testing.expect(elapsed_ms < 65);

    // Verify final result: (100 + 10) + (100 + 20) = 230
    const out_repo = repo_reg.get("pipeline_memory").?;
    const payload = out_repo.readPayload("joined").?;
    const slice = payload.asSlice(FinalResult);
    try testing.expectEqual(@as(usize, 1), slice.len);
    try testing.expectEqual(@as(u64, 230), slice[0].total);
}

// -------------------------------------------------------------------------
// Test 2: Multi-Branch Fan-Out / Fan-In (4 parallel branches)
// -------------------------------------------------------------------------

const MultiBranchInputs = struct {
    stream: []const SampleItem,
    branch_id: u32 = 0,
};

const MultiBranchTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *MultiBranchTask, alloc: std.mem.Allocator, inputs: MultiBranchInputs) ![]const SampleItem {
        _ = recordEnter();
        defer recordExit();

        sleepMs(30);

        const slice = try alloc.alloc(SampleItem, 1);
        slice[0] = .{
            .id = inputs.branch_id,
            .val = inputs.stream[0].val + @as(u64, inputs.branch_id),
        };
        return slice;
    }
};

const MultiAggregatorInputs = struct {
    in_merged: []const SampleItem,
};

const MultiAggregatorTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *MultiAggregatorTask, alloc: std.mem.Allocator, inputs: MultiAggregatorInputs) ![]const FinalResult {
        var sum: u64 = 0;
        for (inputs.in_merged) |item| {
            sum += item.val;
        }
        const slice = try alloc.alloc(FinalResult, 1);
        slice[0] = .{ .total = sum };
        return slice;
    }
};

test "ARCH-017 Phase 17.3: Multi-Branch Fan-Out / Fan-In executes 4 parallel branches concurrently" {
    resetConcurrencyTracker();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root_desc = plugin.defineTaskService(DiamondRootTask, .{ .name = "multi_root" });
    const branch_desc = plugin.defineTaskService(MultiBranchTask, .{ .name = "multi_branch" });
    const agg_desc = plugin.defineTaskService(MultiAggregatorTask, .{ .name = "multi_agg" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ root_desc, branch_desc, agg_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "dag_multi_branch_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("dag_multi_branch_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  scheduler: dag
        \\  workers: 4
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: root
        \\        uses: dag_multi_branch_demo/multi_root
        \\        outputs:
        \\          seed:
        \\            datasource: pipeline_memory
        \\
        \\      - id: b1
        \\        uses: dag_multi_branch_demo/multi_branch
        \\        inputs:
        \\          stream: root.seed
        \\        params:
        \\          branch_id: 1
        \\        outputs:
        \\          out_1:
        \\            datasource: pipeline_memory
        \\
        \\      - id: b2
        \\        uses: dag_multi_branch_demo/multi_branch
        \\        inputs:
        \\          stream: root.seed
        \\        params:
        \\          branch_id: 2
        \\        outputs:
        \\          out_2:
        \\            datasource: pipeline_memory
        \\
        \\      - id: b3
        \\        uses: dag_multi_branch_demo/multi_branch
        \\        inputs:
        \\          stream: root.seed
        \\        params:
        \\          branch_id: 3
        \\        outputs:
        \\          out_3:
        \\            datasource: pipeline_memory
        \\
        \\      - id: b4
        \\        uses: dag_multi_branch_demo/multi_branch
        \\        inputs:
        \\          stream: root.seed
        \\        params:
        \\          branch_id: 4
        \\        outputs:
        \\          out_4:
        \\            datasource: pipeline_memory
        \\
        \\      - id: aggregate
        \\        uses: dag_multi_branch_demo/multi_agg
        \\        inputs:
        \\          in_merged: merge(b1.out_1, b2.out_2, b3.out_3, b4.out_4)
        \\        outputs:
        \\          aggregated:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    const start_time = flowdata.engine.nowNs();
    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());
    const elapsed_ms = (flowdata.engine.nowNs() - start_time) / 1_000_000;

    try testing.expectEqual(@as(usize, 6), summary.steps_executed);
    try testing.expect(!summary.halted_early);

    // High degree of concurrency reached across the 4 branches (at least 3-4 concurrent)
    try testing.expect(global_max_concurrent.load(.acquire) >= 3);

    // Sequential would take: 30ms * 4 = 120ms minimum.
    // Concurrent completes in ~35-70ms.
    try testing.expect(elapsed_ms < 85);

    // Verify sum: (100+1) + (100+2) + (100+3) + (100+4) = 410
    const out_repo = repo_reg.get("pipeline_memory").?;
    const payload = out_repo.readPayload("aggregated").?;
    const slice = payload.asSlice(FinalResult);
    try testing.expectEqual(@as(usize, 1), slice.len);
    try testing.expectEqual(@as(u64, 410), slice[0].total);
}

// -------------------------------------------------------------------------
// Test 3: Concurrent Cancellation and Deterministic Error Handling
// -------------------------------------------------------------------------

const FailingTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *FailingTask) ![]const SampleItem {
        return error.SimulatedTaskError;
    }
};

const SlowTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *SlowTask, alloc: std.mem.Allocator) ![]const SampleItem {
        sleepMs(50);
        const slice = try alloc.alloc(SampleItem, 1);
        slice[0] = .{ .id = 99, .val = 999 };
        return slice;
    }
};

test "ARCH-017 Phase 17.3: Concurrent Cancellation safely stops execution on fatal error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fail_desc = plugin.defineTaskService(FailingTask, .{ .name = "fail_task" });
    const slow_desc = plugin.defineTaskService(SlowTask, .{ .name = "slow_task" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ fail_desc, slow_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "cancel_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("cancel_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  scheduler: dag
        \\  workers: 4
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: branch_fail
        \\        uses: cancel_demo/fail_task
        \\        outputs:
        \\          out_fail:
        \\            datasource: pipeline_memory
        \\
        \\      - id: branch_slow
        \\        uses: cancel_demo/slow_task
        \\        outputs:
        \\          out_slow:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    // Engine must detect error.SimulatedTaskError from branch_fail, trigger clean cancellation,
    // wait for in-flight tasks without leaking or deadlocking, and return error.TaskExecutionFailed.
    const result = engine.run(flowdata.dataflow.PayloadHandle.empty());
    try testing.expectError(error.TaskExecutionFailed, result);
}

// -------------------------------------------------------------------------
// Test 4: Nested Parallelism (DAG Coordinator + Intra-Step Elemental Lifting)
// -------------------------------------------------------------------------

const BatchProducerTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *BatchProducerTask, alloc: std.mem.Allocator) ![]const SampleItem {
        const slice = try alloc.alloc(SampleItem, 16);
        for (slice, 0..) |*item, idx| {
            item.* = .{
                .id = @intCast(idx),
                .val = @intCast(idx * 10),
            };
        }
        return slice;
    }
};

const ElementalDoubleTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    // Elemental lifting: 1 -> 1
    pub fn execute(_: *ElementalDoubleTask, item: SampleItem) !SampleItem {
        return .{
            .id = item.id,
            .val = item.val * 2,
        };
    }
};

const PlainWorkerTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *PlainWorkerTask, alloc: std.mem.Allocator) ![]const SampleItem {
        const slice = try alloc.alloc(SampleItem, 1);
        slice[0] = .{ .id = 999, .val = 777 };
        return slice;
    }
};

const NestedJoinInputs = struct {
    lifted: []const SampleItem,
    plain: []const SampleItem,
};

const NestedJoinTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };
    pub fn execute(_: *NestedJoinTask, alloc: std.mem.Allocator, inputs: NestedJoinInputs) ![]const FinalResult {
        var sum: u64 = 0;
        for (inputs.lifted) |item| {
            sum += item.val;
        }
        for (inputs.plain) |item| {
            sum += item.val;
        }
        const slice = try alloc.alloc(FinalResult, 1);
        slice[0] = .{ .total = sum };
        return slice;
    }
};

test "ARCH-017 Phase 17.3: Nested Parallelism (Intra-step lifting inside DAG coordinator)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prod_desc = plugin.defineTaskService(BatchProducerTask, .{ .name = "batch_producer" });
    const lift_desc = plugin.defineTaskService(ElementalDoubleTask, .{
        .name = "elemental_double",
        .lift = .elemental,
    });
    const plain_desc = plugin.defineTaskService(PlainWorkerTask, .{ .name = "plain_worker" });
    const join_desc = plugin.defineTaskService(NestedJoinTask, .{ .name = "nested_join" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ prod_desc, lift_desc, plain_desc, join_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "nested_demo",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("nested_demo", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  scheduler: dag
        \\  workers: 4
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: producer
        \\        uses: nested_demo/batch_producer
        \\        outputs:
        \\          batch:
        \\            datasource: pipeline_memory
        \\
        \\      - id: parallel_lift_branch
        \\        uses: nested_demo/elemental_double
        \\        inputs:
        \\          stream: producer.batch
        \\        outputs:
        \\          doubled:
        \\            datasource: pipeline_memory
        \\
        \\      - id: plain_branch
        \\        uses: nested_demo/plain_worker
        \\        outputs:
        \\          extra:
        \\            datasource: pipeline_memory
        \\
        \\      - id: join_step
        \\        uses: nested_demo/nested_join
        \\        inputs:
        \\          lifted: parallel_lift_branch.doubled
        \\          plain: plain_branch.extra
        \\        outputs:
        \\          nested_result:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());
    try testing.expectEqual(@as(usize, 4), summary.steps_executed);
    try testing.expect(!summary.halted_early);

    // Verify correct calculation:
    // producer items: 0*10 .. 15*10. Sum = 10 * (15*16 / 2) = 1200.
    // doubled: 1200 * 2 = 2400.
    // plain: 777.
    // Total = 2400 + 777 = 3177.
    const out_repo = repo_reg.get("pipeline_memory").?;
    const payload = out_repo.readPayload("nested_result").?;
    const slice = payload.asSlice(FinalResult);
    try testing.expectEqual(@as(usize, 1), slice.len);
    try testing.expectEqual(@as(u64, 3177), slice[0].total);
}

// -------------------------------------------------------------------------
// Test 5: Fallback to Sequential when workers: 1
// -------------------------------------------------------------------------

test "ARCH-017 Phase 17.3: Single-worker (workers: 1) falls back to topological sequential" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root_desc = plugin.defineTaskService(DiamondRootTask, .{ .name = "diamond_root" });
    const branch_a_desc = plugin.defineTaskService(DiamondBranchATask, .{ .name = "branch_a" });
    const branch_b_desc = plugin.defineTaskService(DiamondBranchBTask, .{ .name = "branch_b" });
    const join_desc = plugin.defineTaskService(DiamondJoinTask, .{ .name = "diamond_join" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ root_desc, branch_a_desc, branch_b_desc, join_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "dag_diamond_single",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("dag_diamond_single", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();

    const MemoryRepository = @import("flowdata_extensions").datasource.MemoryRepository;
    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  scheduler: dag
        \\  workers: 1
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: root
        \\        uses: dag_diamond_single/diamond_root
        \\        outputs:
        \\          seed:
        \\            datasource: pipeline_memory
        \\
        \\      - id: left_branch
        \\        uses: dag_diamond_single/branch_a
        \\        inputs:
        \\          stream: root.seed
        \\        outputs:
        \\          left_out:
        \\            datasource: pipeline_memory
        \\
        \\      - id: right_branch
        \\        uses: dag_diamond_single/branch_b
        \\        inputs:
        \\          stream: root.seed
        \\        outputs:
        \\          right_out:
        \\            datasource: pipeline_memory
        \\
        \\      - id: join_step
        \\        uses: dag_diamond_single/diamond_join
        \\        inputs:
        \\          in_merged: merge(left_branch.left_out, right_branch.right_out)
        \\        outputs:
        \\          joined:
        \\            datasource: pipeline_memory
    ;

    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{});
    var engine = flowdata.engine.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    const summary = try engine.run(flowdata.dataflow.PayloadHandle.empty());
    try testing.expectEqual(@as(usize, 4), summary.steps_executed);
    try testing.expect(!summary.halted_early);

    const out_repo = repo_reg.get("pipeline_memory").?;
    const payload = out_repo.readPayload("joined").?;
    const slice = payload.asSlice(FinalResult);
    try testing.expectEqual(@as(usize, 1), slice.len);
    try testing.expectEqual(@as(u64, 230), slice[0].total);
}
