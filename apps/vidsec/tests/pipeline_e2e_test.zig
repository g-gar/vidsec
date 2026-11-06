const std = @import("std");
const vidsec = @import("vidsec");
const abi_lib = @import("vidsec_abi");
const dataflow = vidsec.dataflow;
const pipeline = vidsec.pipeline;
const yaml_mod = vidsec.yaml;

const PipelineEngine = pipeline.PipelineEngine;
const ModuleRegistry = pipeline.ModuleRegistry;
const RepositoryRegistry = pipeline.repository.RepositoryRegistry;
const PayloadHandle = dataflow.PayloadHandle;

test "E2E: Dynamic libanalyzer.so loading, probe_file Black Box task, and RAM routing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\runtime:
        \\  workers: 1
        \\datasources:
        \\  pipeline_memory:
        \\    driver: memory
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: stage0_probe_file
        \\        uses: analyzer/probe_file
        \\        in: stream
        \\        outputs:
        \\          coordination:
        \\            datasource: pipeline_memory
        \\      - router: check_risk
        \\        cases:
        \\          - when: "verdict == 'FLAGGED'"
        \\            goto: flagged_flow
        \\        default: clean_flow
        \\  flagged_flow:
        \\    steps:
        \\      - id: audit_mp4_step
        \\        uses: analyzer/probe_mp4
        \\        in: stream
        \\        outputs:
        \\          audit_out:
        \\            datasource: pipeline_memory
        \\  clean_flow:
        \\    steps:
        \\      - id: pass_audit_step
        \\        uses: analyzer/probe_mp4
        \\        in: stream
    ;

    const ast = try yaml_mod.loadPipelineAstFromYaml(alloc, yaml_text, .{});

    var modules = ModuleRegistry.init(alloc);
    defer modules.deinit();
    _ = try modules.loadSharedLibrary("analyzer", "./zig-out/lib/libanalyzer.so");

    var repos = RepositoryRegistry.init(alloc);
    defer repos.deinit();
    try vidsec.extensions.datasources.registerDefaultDrivers(&repos);

    var engine = PipelineEngine.init(alloc, ast, &modules, &repos);

    // Build sample MP4 with polyglot ZIP EOCD at the tail
    var sample_mp4: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xCAFE1234);
    prng.fill(&sample_mp4);
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    @memcpy(sample_mp4[0..mp4_hdr.len], mp4_hdr);
    @memcpy(sample_mp4[sample_mp4.len - 22 .. sample_mp4.len - 18], "PK\x05\x06");

    const input_payload = PayloadHandle.fromSlice(u8, &sample_mp4);
    const summary = try engine.run(input_payload);

    try std.testing.expectEqual(@as(usize, 2), summary.steps_executed);
    try std.testing.expectEqual(@as(usize, 1), summary.routers_evaluated);
    try std.testing.expectEqualStrings("flagged_flow", summary.final_pipeline);

    const mem_repo = repos.get("pipeline_memory").?;
    const coord_payload = mem_repo.readPayload("coordination").?;
    try std.testing.expect(coord_payload.len > 0);
}

test "E2E: Clean MP4 file passes probe_file and routes to clean_flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\runtime:
        \\  workers: 1
        \\datasources:
        \\  pipeline_memory:
        \\    driver: memory
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: stage0_probe_file
        \\        uses: analyzer/probe_file
        \\        in: stream
        \\        outputs:
        \\          coordination:
        \\            datasource: pipeline_memory
        \\      - router: check_risk
        \\        cases:
        \\          - when: "verdict == 'FLAGGED'"
        \\            goto: flagged_flow
        \\        default: clean_flow
        \\  flagged_flow:
        \\    steps:
        \\      - id: audit_mp4_step
        \\        uses: analyzer/probe_mp4
        \\        in: stream
        \\  clean_flow:
        \\    steps:
        \\      - id: pass_audit_step
        \\        uses: analyzer/probe_mp4
        \\        in: stream
        \\        outputs:
        \\          clean_mp4_out:
        \\            datasource: pipeline_memory
    ;

    const ast = try yaml_mod.loadPipelineAstFromYaml(alloc, yaml_text, .{});

    var modules = ModuleRegistry.init(alloc);
    defer modules.deinit();
    _ = try modules.loadSharedLibrary("analyzer", "./zig-out/lib/libanalyzer.so");

    var repos = RepositoryRegistry.init(alloc);
    defer repos.deinit();
    try vidsec.extensions.datasources.registerDefaultDrivers(&repos);

    var engine = PipelineEngine.init(alloc, ast, &modules, &repos);

    // Build clean MP4 (no secondary signatures)
    var clean_mp4: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x11223344);
    prng.fill(&clean_mp4);
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    @memcpy(clean_mp4[0..mp4_hdr.len], mp4_hdr);

    const input_payload = PayloadHandle.fromSlice(u8, &clean_mp4);
    const summary = try engine.run(input_payload);

    try std.testing.expectEqual(@as(usize, 2), summary.steps_executed);
    try std.testing.expectEqual(@as(usize, 1), summary.routers_evaluated);
    try std.testing.expectEqualStrings("clean_flow", summary.final_pipeline);

    const mem_repo = repos.get("pipeline_memory").?;
    const clean_payload = mem_repo.readPayload("clean_mp4_out").?;
    try std.testing.expect(clean_payload.len > 0);
}
