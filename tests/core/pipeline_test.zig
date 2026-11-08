const std = @import("std");
const vidsec = @import("vidsec");
const abi_lib = @import("flowdata_abi");
const dataflow = vidsec.dataflow;
const pipeline = vidsec.pipeline;
const yaml_core = vidsec.yaml;

const PipelineEngine = pipeline.PipelineEngine;
const ModuleRegistry = pipeline.ModuleRegistry;
const RepositoryRegistry = pipeline.repository.RepositoryRegistry;
const MemoryRepository = vidsec.extensions.datasources.MemoryRepository;
const PayloadHandle = dataflow.PayloadHandle;

const TriageInput = struct {
    file_bytes: []const u8,
};

const TriageOutput = struct {
    format: []const u8,
    is_safe: bool,
    score: f64,
};

fn sampleTriageTask(alloc: std.mem.Allocator, in: []const u8) !TriageOutput {
    _ = alloc;
    const is_mp4 = in.len >= 8 and std.mem.eql(u8, in[4..8], "ftyp");
    return .{
        .format = if (is_mp4) "isobmff" else "unknown",
        .is_safe = is_mp4,
        .score = if (is_mp4) 9.5 else 1.0,
    };
}

fn sampleQuarantineTask(alloc: std.mem.Allocator, in: TriageOutput) !TriageOutput {
    _ = alloc;
    return in;
}

test "Modern PipelineEngine: Black Box execution, RAM routers, and zero-copy MemoryRepository" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\runtime:
        \\  workers: 2
        \\datasources:
        \\  pipeline_memory:
        \\    driver: memory
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: triage_step
        \\        uses: analyzer/triage
        \\        in: stream
        \\        outputs:
        \\          triage_res:
        \\            datasource: pipeline_memory
        \\      - router: check_verdict
        \\        cases:
        \\          - when: "is_safe == false"
        \\            goto: quarantine_flow
        \\        default: finalize
        \\  quarantine_flow:
        \\    steps:
        \\      - id: quarantine_step
        \\        uses: analyzer/quarantine
        \\        in: triage_step
        \\  finalize:
        \\    steps:
        \\      - id: finalize_step
        \\        uses: analyzer/quarantine
        \\        in: triage_step
    ;

    const ast = try yaml_core.loadPipelineAstFromYaml(alloc, yaml_text, .{});

    // 1. Setup Module Registry with mock Black Box tasks
    var modules = ModuleRegistry.init(alloc);
    defer modules.deinit();

    const tasks = [_]abi_lib.TaskDescriptor_ABI{
        abi_lib.defineBlackBoxTask(.{
            .name = "triage",
            .run = sampleTriageTask,
        }),
        abi_lib.defineBlackBoxTask(.{
            .name = "quarantine",
            .run = sampleQuarantineTask,
        }),
    };

    var manifest = abi_lib.ModuleManifest_ABI{
        .module_name = "analyzer",
        .module_version = .{ .major = 2, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    try modules.registerStaticModule("analyzer", &manifest);

    // 2. Setup Repository Registry
    var repos = RepositoryRegistry.init(alloc);
    defer repos.deinit();

    var mem_repo = MemoryRepository.init(alloc);
    try repos.register("pipeline_memory", mem_repo.storageRepository());

    // 3. Initialize Engine
    var engine = PipelineEngine.init(alloc, ast, &modules, &repos);

    // Test Case A: Safe MP4 File -> branches to "finalize"
    {
        const dummy_mp4 = "\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom";
        const input_payload = PayloadHandle.fromSlice(u8, dummy_mp4);

        const summary = try engine.run(input_payload);
        try std.testing.expectEqual(@as(usize, 2), summary.steps_executed); // triage_step + finalize_step
        try std.testing.expectEqual(@as(usize, 1), summary.routers_evaluated);
        try std.testing.expectEqualStrings("finalize", summary.final_pipeline);

        // Verify MemoryRepository contains output
        const repo = repos.get("pipeline_memory").?;
        const saved_payload = repo.readPayload("triage_res").?;
        const res_out = saved_payload.asScalar(TriageOutput);
        try std.testing.expectEqualStrings("isobmff", res_out.format);
        try std.testing.expect(res_out.is_safe);
    }

    // Test Case B: Dangerous / Corrupted File -> branches to "quarantine_flow"
    {
        const dangerous_file = "\x7fELF\x02\x01\x01\x00";
        const input_payload = PayloadHandle.fromSlice(u8, dangerous_file);

        const summary = try engine.run(input_payload);
        try std.testing.expectEqual(@as(usize, 2), summary.steps_executed); // triage_step + quarantine_step
        try std.testing.expectEqual(@as(usize, 1), summary.routers_evaluated);
        try std.testing.expectEqualStrings("quarantine_flow", summary.final_pipeline);

        const repo = repos.get("pipeline_memory").?;
        const saved_payload = repo.readPayload("triage_res").?;
        const res_out = saved_payload.asScalar(TriageOutput);
        try std.testing.expectEqualStrings("unknown", res_out.format);
        try std.testing.expect(!res_out.is_safe);
    }
}

const SampleItem = struct {
    id: i64,
    is_clean: bool,
    score: f64,
};

fn sampleProducerTask(alloc: std.mem.Allocator, in: []const u8) ![]SampleItem {
    _ = in;
    const items = try alloc.alloc(SampleItem, 4);
    items[0] = .{ .id = 0, .is_clean = true, .score = 10.0 };
    items[1] = .{ .id = 1, .is_clean = false, .score = 20.0 };
    items[2] = .{ .id = 2, .is_clean = true, .score = 30.0 };
    items[3] = .{ .id = 3, .is_clean = false, .score = 40.0 };
    return items;
}

fn sampleIdentityTask(alloc: std.mem.Allocator, in: []const SampleItem) ![]SampleItem {
    _ = alloc;
    return @constCast(in);
}

test "Modern PipelineEngine: Stream Algebra, Slicing, Merging, and Multi-Channel Output Filtering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\runtime:
        \\  workers: 2
        \\datasources:
        \\  pipeline_memory:
        \\    driver: memory
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: split_producer
        \\        uses: test_mod/producer
        \\        in: stream
        \\        outputs:
        \\          clean_channel:
        \\            datasource: pipeline_memory
        \\            filter: "is_clean == true"
        \\          all_channel:
        \\            datasource: pipeline_memory
        \\      - id: slice_consumer
        \\        uses: test_mod/identity
        \\        in: "slice(split_producer.all_channel, 1, 2)"
        \\        outputs:
        \\          sliced_res:
        \\            datasource: pipeline_memory
        \\      - id: merge_consumer
        \\        uses: test_mod/identity
        \\        in: "merge(slice_consumer, split_producer.clean_channel)"
        \\        outputs:
        \\          merged_res:
        \\            datasource: pipeline_memory
        \\      - id: filtered_consumer
        \\        uses: test_mod/identity
        \\        in: split_producer.all_channel
        \\        where: "score > 25.0"
        \\        outputs:
        \\          filtered_res:
        \\            datasource: pipeline_memory
    ;

    const ast = try yaml_core.loadPipelineAstFromYaml(alloc, yaml_text, .{});

    // 1. Setup Module Registry
    var modules = ModuleRegistry.init(alloc);
    defer modules.deinit();

    const tasks = [_]abi_lib.TaskDescriptor_ABI{
        abi_lib.defineBlackBoxTask(.{
            .name = "producer",
            .run = sampleProducerTask,
        }),
        abi_lib.defineBlackBoxTask(.{
            .name = "identity",
            .run = sampleIdentityTask,
        }),
    };

    var manifest = abi_lib.ModuleManifest_ABI{
        .module_name = "test_mod",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };
    try modules.registerStaticModule("test_mod", &manifest);

    // 2. Setup Repository Registry
    var repos = RepositoryRegistry.init(alloc);
    defer repos.deinit();

    var mem_repo = MemoryRepository.init(alloc);
    try repos.register("pipeline_memory", mem_repo.storageRepository());

    // 3. Run PipelineEngine
    var engine = PipelineEngine.init(alloc, ast, &modules, &repos);
    const dummy_bytes = "trigger";
    const summary = try engine.run(PayloadHandle.fromSlice(u8, dummy_bytes));

    try std.testing.expectEqual(@as(usize, 4), summary.steps_executed);

    // 4. Assert Results from MemoryRepository
    const repo = repos.get("pipeline_memory").?;

    // (A) Clean channel should have only is_clean == true items (items 0 and 2)
    const clean_payload = repo.readPayload("clean_channel").?;
    const clean_items = clean_payload.asSlice(SampleItem);
    try std.testing.expectEqual(@as(usize, 2), clean_items.len);
    try std.testing.expectEqual(@as(i64, 0), clean_items[0].id);
    try std.testing.expectEqual(@as(i64, 2), clean_items[1].id);

    // (B) Sliced result should have items offset=1, count=2 (items 1 and 2)
    const sliced_payload = repo.readPayload("sliced_res").?;
    const sliced_items = sliced_payload.asSlice(SampleItem);
    try std.testing.expectEqual(@as(usize, 2), sliced_items.len);
    try std.testing.expectEqual(@as(i64, 1), sliced_items[0].id);
    try std.testing.expectEqual(@as(i64, 2), sliced_items[1].id);

    // (C) Merged result should have 2 (sliced) + 2 (clean) = 4 items
    const merged_payload = repo.readPayload("merged_res").?;
    const merged_items = merged_payload.asSlice(SampleItem);
    try std.testing.expectEqual(@as(usize, 4), merged_items.len);
    try std.testing.expectEqual(@as(i64, 1), merged_items[0].id);
    try std.testing.expectEqual(@as(i64, 2), merged_items[1].id);
    try std.testing.expectEqual(@as(i64, 0), merged_items[2].id);
    try std.testing.expectEqual(@as(i64, 2), merged_items[3].id);

    // (D) Where filtered result should have items where score > 25.0 (items 2 and 3)
    const filtered_payload = repo.readPayload("filtered_res").?;
    const filtered_items = filtered_payload.asSlice(SampleItem);
    try std.testing.expectEqual(@as(usize, 2), filtered_items.len);
    try std.testing.expectEqual(@as(i64, 2), filtered_items[0].id);
    try std.testing.expectEqual(@as(i64, 3), filtered_items[1].id);
}
