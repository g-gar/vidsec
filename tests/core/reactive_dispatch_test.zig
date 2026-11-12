//! Flowdata Reactive Push Dispatch Tests (ARCH-014).
//!
//! Comprehensive verification suite:
//! 1. Subscription map indexing for declared datasources and default streams.
//! 2. Single-item reactive dispatch to root subscribers via `emitRecord`.
//! 3. True multi-branch concurrent fan-out across WorkerPool for a single emitted event.
//! 4. Downstream DAG propagation from an emitted root record through intermediate channels.
//! 5. Decoupled `RecordEmitter` interface for external producers.
//! 6. Multiple sequential emissions without state corruption or memory leaks.

const std = @import("std");
const testing = std.testing;
const flowdata = @import("flowdata");
const plugin = @import("flowdata_plugin");
const datasource_ext = @import("flowdata_extensions").datasource;
const MemoryRepository = datasource_ext.MemoryRepository;

pub const SampleTarget = struct {
    series_id: []const u8,
    action: []const u8 = "sync",
};

pub const SampleDetails = struct {
    series_id: []const u8,
    title: []const u8,
    chapter_count: u32,
};

pub const SampleChapter = struct {
    chapter_id: []const u8,
    number: u32,
};

fn sleepMs(ms: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&ts, null);
}

// Global atomic concurrency tracker for fan-out verification
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
// Mock Task Services
// -------------------------------------------------------------------------

const TargetInputs = struct {
    input: []const SampleTarget,
};

const DetailsInputs = struct {
    input: []const SampleDetails,
};

const ChapterInputs = struct {
    input: []const SampleChapter,
};

pub const MockFetchDetailsTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };

    pub fn execute(_: *MockFetchDetailsTask, alloc: std.mem.Allocator, in: TargetInputs) ![]const SampleDetails {
        _ = recordEnter();
        defer recordExit();

        sleepMs(30);

        const out = try alloc.alloc(SampleDetails, in.input.len);
        for (in.input, 0..) |target, idx| {
            out[idx] = .{
                .series_id = target.series_id,
                .title = "Mock Series",
                .chapter_count = 10,
            };
        }
        return out;
    }
};

pub const MockAltScraperTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };

    pub fn execute(_: *MockAltScraperTask, alloc: std.mem.Allocator, in: TargetInputs) ![]const SampleDetails {
        _ = recordEnter();
        defer recordExit();

        sleepMs(30);

        const out = try alloc.alloc(SampleDetails, in.input.len);
        for (in.input, 0..) |target, idx| {
            out[idx] = .{
                .series_id = target.series_id,
                .title = "Alternative Cover",
                .chapter_count = 0,
            };
        }
        return out;
    }
};

pub const MockFetchChaptersTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };

    pub fn execute(_: *MockFetchChaptersTask, alloc: std.mem.Allocator, in: DetailsInputs) ![]const SampleChapter {
        var chapters: std.ArrayListUnmanaged(SampleChapter) = .empty;
        for (in.input) |det| {
            for (0..det.chapter_count) |i| {
                try chapters.append(alloc, .{
                    .chapter_id = "c-101",
                    .number = @intCast(i + 1),
                });
            }
        }
        return chapters.toOwnedSlice(alloc);
    }
};

pub const MockSinkTask = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };

    pub fn execute(_: *MockSinkTask, alloc: std.mem.Allocator, in: ChapterInputs) ![]const SampleChapter {
        const out = try alloc.alloc(SampleChapter, in.input.len);
        @memcpy(out, in.input);
        return out;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "ARCH-014: PushReactor subscription map indexes declared datasources and defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const task_a_desc = plugin.defineTaskService(MockFetchDetailsTask, .{ .name = "fetch_details" });
    const task_b_desc = plugin.defineTaskService(MockAltScraperTask, .{ .name = "scrape_alt" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ task_a_desc, task_b_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "reactor_indexing_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("reactor_indexing_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\datasources:
        \\  tracked_targets:
        \\    driver: memory
        \\  other_stream:
        \\    driver: memory
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_a
        \\        uses: reactor_indexing_test/fetch_details
        \\        inputs:
        \\          input: tracked_targets
        \\
        \\      - id: step_b
        \\        uses: reactor_indexing_test/scrape_alt
        \\        inputs:
        \\          input: tracked_targets
        \\
        \\      - id: step_c
        \\        uses: reactor_indexing_test/fetch_details
        \\        inputs:
        \\          input: other_stream
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    var reactor = try engine.createReactor("main");
    defer reactor.deinit();

    // Verify tracked_targets has 2 subscribers (step_a and step_b)
    try testing.expect(reactor.hasSubscribers("tracked_targets"));
    const targets_subs = reactor.getSubscribers("tracked_targets");
    try testing.expectEqual(@as(usize, 2), targets_subs.len);

    // Verify other_stream has 1 subscriber (step_c)
    try testing.expect(reactor.hasSubscribers("other_stream"));
    const other_subs = reactor.getSubscribers("other_stream");
    try testing.expectEqual(@as(usize, 1), other_subs.len);

    // Verify non-existent source has 0 subscribers
    try testing.expect(!reactor.hasSubscribers("non_existent"));
}

test "ARCH-014: Single-item reactive dispatch to root subscribers via emitRecord" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const task_desc = plugin.defineTaskService(MockFetchDetailsTask, .{ .name = "fetch_details" });
    var tasks = [_]plugin.TaskDescriptor_ABI{task_desc};
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "reactor_single_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("reactor_single_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\datasources:
        \\  tracked_targets:
        \\    driver: memory
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: fetch_details
        \\        uses: reactor_single_test/fetch_details
        \\        inputs:
        \\          input: tracked_targets
        \\        outputs:
        \\          series_details:
        \\            datasource: pipeline_memory
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    var reactor = try engine.createReactor("main");
    defer reactor.deinit();

    // Emit a single item
    const target = SampleTarget{
        .series_id = "series-001",
        .action = "sync",
    };

    const summary = try reactor.emitRecord("tracked_targets", target);
    try testing.expectEqual(@as(usize, 1), summary.steps_executed);
    try testing.expect(!summary.halted_early);
    try testing.expectEqual(@as(usize, 1), reactor.total_emitted);
    try testing.expectEqual(@as(usize, 1), reactor.total_dispatched);

    // Verify output stored in pipeline_memory repository
    const stored = mem_repo.readPayload("series_details");
    try testing.expect(stored != null);
    const details_slice = stored.?.asSlice(SampleDetails);
    try testing.expectEqual(@as(usize, 1), details_slice.len);
    try testing.expectEqualStrings("series-001", details_slice[0].series_id);
    try testing.expectEqualStrings("Mock Series", details_slice[0].title);
}

test "ARCH-014: True multi-branch concurrent fan-out across WorkerPool for emitted item" {
    resetConcurrencyTracker();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const task_a_desc = plugin.defineTaskService(MockFetchDetailsTask, .{ .name = "fetch_details" });
    const task_b_desc = plugin.defineTaskService(MockAltScraperTask, .{ .name = "scrape_alt" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ task_a_desc, task_b_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "reactor_fanout_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("reactor_fanout_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  scheduler: dag
        \\  workers: 4
        \\datasources:
        \\  tracked_targets:
        \\    driver: memory
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: branch_alpha
        \\        uses: reactor_fanout_test/fetch_details
        \\        inputs:
        \\          input: tracked_targets
        \\        outputs:
        \\          alpha_out:
        \\            datasource: pipeline_memory
        \\
        \\      - id: branch_beta
        \\        uses: reactor_fanout_test/scrape_alt
        \\        inputs:
        \\          input: tracked_targets
        \\        outputs:
        \\          beta_out:
        \\            datasource: pipeline_memory
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    var reactor = try engine.createReactor("main");
    defer reactor.deinit();

    const target = SampleTarget{
        .series_id = "concurrent-manga-999",
        .action = "sync",
    };

    const summary = try reactor.emitRecord("tracked_targets", target);
    try testing.expectEqual(@as(usize, 2), summary.steps_executed);

    // Verify true concurrent parallel execution: max concurrent tasks in flight >= 2
    const max_concurrent = global_max_concurrent.load(.acquire);
    try testing.expect(max_concurrent >= 2);
}

test "ARCH-014: Downstream DAG propagation from emitted root record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const task1_desc = plugin.defineTaskService(MockFetchDetailsTask, .{ .name = "fetch_details" });
    const task2_desc = plugin.defineTaskService(MockFetchChaptersTask, .{ .name = "fetch_chapters" });
    const task3_desc = plugin.defineTaskService(MockSinkTask, .{ .name = "save_chapters" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ task1_desc, task2_desc, task3_desc };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "reactor_chain_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("reactor_chain_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\runtime:
        \\  scheduler: dag
        \\  workers: 2
        \\datasources:
        \\  tracked_targets:
        \\    driver: memory
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_root
        \\        uses: reactor_chain_test/fetch_details
        \\        inputs:
        \\          input: tracked_targets
        \\        outputs:
        \\          series_details:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_chapters
        \\        uses: reactor_chain_test/fetch_chapters
        \\        inputs:
        \\          input: step_root.series_details
        \\        outputs:
        \\          discovered_chapters:
        \\            datasource: pipeline_memory
        \\
        \\      - id: step_sink
        \\        uses: reactor_chain_test/save_chapters
        \\        inputs:
        \\          input: step_chapters.discovered_chapters
        \\        outputs:
        \\          final_chapters:
        \\            datasource: pipeline_memory
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    var reactor = try engine.createReactor("main");
    defer reactor.deinit();

    const target = SampleTarget{
        .series_id = "chain-target-1",
        .action = "sync",
    };

    const summary = try reactor.emitRecord("tracked_targets", target);
    try testing.expectEqual(@as(usize, 3), summary.steps_executed);

    // Verify final sink output has all 10 chapters propagated along the 3-step DAG
    const final_stored = mem_repo.readPayload("final_chapters");
    try testing.expect(final_stored != null);
    const chapters = final_stored.?.asSlice(SampleChapter);
    try testing.expectEqual(@as(usize, 10), chapters.len);
    try testing.expectEqual(@as(u32, 1), chapters[0].number);
    try testing.expectEqual(@as(u32, 10), chapters[9].number);
}

test "ARCH-014: Decoupled RecordEmitter handle used by external producer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const task_desc = plugin.defineTaskService(MockFetchDetailsTask, .{ .name = "fetch_details" });
    var tasks = [_]plugin.TaskDescriptor_ABI{task_desc};
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "reactor_emitter_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("reactor_emitter_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\datasources:
        \\  tracked_targets:
        \\    driver: memory
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: fetch_details
        \\        uses: reactor_emitter_test/fetch_details
        \\        inputs:
        \\          input: tracked_targets
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    var reactor = try engine.createReactor("main");
    defer reactor.deinit();

    // Obtain the decoupled RecordEmitter interface
    const emitter = reactor.emitter();

    // External producer calls emitRecord without knowing about PushReactor internals
    try emitter.emitRecord("tracked_targets", SampleTarget{
        .series_id = "decoupled-producer-01",
    });

    try testing.expectEqual(@as(usize, 1), reactor.total_emitted);
    try testing.expectEqual(@as(usize, 1), reactor.total_dispatched);
}

test "ARCH-014: Multiple sequential emissions without state corruption" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const task_desc = plugin.defineTaskService(MockFetchDetailsTask, .{ .name = "fetch_details" });
    var tasks = [_]plugin.TaskDescriptor_ABI{task_desc};
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "reactor_seq_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("reactor_seq_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    var mem_repo = MemoryRepository.init(alloc);
    try repo_reg.register("pipeline_memory", mem_repo.storageRepository());

    const pipeline_yaml =
        \\version: 2
        \\datasources:
        \\  tracked_targets:
        \\    driver: memory
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: fetch_details
        \\        uses: reactor_seq_test/fetch_details
        \\        inputs:
        \\          input: tracked_targets
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    var reactor = try engine.createReactor("main");
    defer reactor.deinit();

    // Emit 5 distinct items sequentially
    for (0..5) |i| {
        var id_buf: [32]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "manga-{d}", .{i});

        const summary = try reactor.emitRecord("tracked_targets", SampleTarget{
            .series_id = id_str,
        });
        try testing.expectEqual(@as(usize, 1), summary.steps_executed);
    }

    try testing.expectEqual(@as(usize, 5), reactor.total_emitted);
    try testing.expectEqual(@as(usize, 5), reactor.total_dispatched);
}
