const std = @import("std");
const vidsec = @import("vidsec");
const abi_lib = @import("vidsec_abi");
const dataflow = vidsec.dataflow;
const pipeline = vidsec.pipeline;
const yaml_core = vidsec.yaml;

const PipelineEngine = pipeline.PipelineEngine;
const ModuleRegistry = pipeline.ModuleRegistry;
const RepositoryRegistry = pipeline.repository.RepositoryRegistry;
const MemoryRepository = pipeline.repository.MemoryRepository;
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
