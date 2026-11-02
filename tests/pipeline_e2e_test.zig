const std = @import("std");
const vidsec = @import("vidsec");
const abi = @import("vidsec_abi");

const yaml_core = vidsec.yaml;
const sqlite_core = vidsec.sqlite;
const pipeline_core = vidsec.pipeline;
const triage = vidsec.plugin.triage;
const ir = vidsec.plugin.ir;
const forensics = vidsec.plugin.forensics;

test "E2E: PipelineEngine integration with real triage/probe_file plugin (polyglot MP4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schemas_bytes = try pipeline_core.readFileBytes(arena, "configs/schemas.yaml");
    const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schemas_bytes, null);

    const pipeline_yaml =
        \\version: 2
        \\engine:
        \\  schemas: "configs/schemas.yaml"
        \\modules:
        \\  triage: { path: "./zig-out/lib/libtriage.so" }
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - task: stage0_probe
        \\        use: triage/probe_file
        \\        input:
        \\          stream: { from: file }
        \\        params:
        \\          file_path: "sample_polyglot.mp4"
        \\          max_file_size_mb: 100
        \\        output:
        \\          into: file_triage
        \\
        \\      - task: promote_triage_flags_to_findings
        \\        use: sql_rule
        \\        query: |
        \\          SELECT 'STAGE0_TRIAGE' AS rule_id,
        \\                 CASE WHEN verdict = 'DROP' THEN 2 ELSE 1 END AS severity,
        \\                 COALESCE(zip_eocd_offset, 0) AS file_offset,
        \\                 identified_format AS region_tag,
        \\                 mid_entropy AS measured_value,
        \\                 flags_csv AS message
        \\          FROM file_triage WHERE verdict != 'PASS'
        \\        output:
        \\          into: audit_findings
    ;

    const config = try yaml_core.PipelineConfig.parse(arena, pipeline_yaml, null);

    var db_runtime = try sqlite_core.SqliteRuntime.initWithSettings(
        std.testing.allocator,
        config.engine,
        null,
        &catalog,
    );
    defer db_runtime.deinit();

    var registry = abi.ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerStaticModule("triage", &triage.manifest);

    var eng = pipeline_core.PipelineEngine.init(
        std.testing.allocator,
        &config,
        &catalog,
        &registry,
        &db_runtime,
    );
    defer eng.deinit();

    try eng.preflightValidate();

    // Build an 8 KB MP4 with high-entropy media payload + appended ZIP EOCD at the tail
    var sample_mp4: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x99887766);
    prng.fill(&sample_mp4);
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    @memcpy(sample_mp4[0..mp4_hdr.len], mp4_hdr);
    @memcpy(sample_mp4[sample_mp4.len - 22 .. sample_mp4.len - 18], "PK\x05\x06");

    var artifacts = try pipeline_core.ArtifactStore.init(std.testing.allocator, &sample_mp4);
    defer artifacts.deinit();

    const summary = try eng.run(&artifacts);
    try std.testing.expectEqual(@as(usize, 2), summary.steps_executed);
    try std.testing.expectEqual(@as(usize, 2), summary.total_rows_emitted);

    var stmt = try db_runtime.db.prepareReadOnly(
        "SELECT verdict, identified_format, mime_type, flags_csv, zip_eocd_offset, report_json FROM file_triage",
    );
    defer stmt.deinit();
    const row = (try stmt.step()).?;
    try std.testing.expectEqualStrings("FLAGGED", row.text(0));
    try std.testing.expectEqualStrings("mp4", row.text(1));
    try std.testing.expectEqualStrings("video/mp4", row.text(2));
    try std.testing.expectEqualStrings("SECONDARY_SIGNATURE_ZIP_EOCD_FOUND", row.text(3));
    try std.testing.expectEqual(@as(i64, 8170), row.int64(4));
    try std.testing.expect(std.mem.indexOf(u8, row.text(5), "\"verdict\":\"FLAGGED\"") != null);
}

test "E2E: configs/pipeline.yaml clean MP4 execution reaches video_verified_clean" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schemas_bytes = try pipeline_core.readFileBytes(arena, "configs/schemas.yaml");
    const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schemas_bytes, null);

    const pipeline_bytes = try pipeline_core.readFileBytes(arena, "configs/pipeline.yaml");
    const config = try yaml_core.PipelineConfig.parse(arena, pipeline_bytes, null);

    var db_runtime = try sqlite_core.SqliteRuntime.initWithSettings(
        std.testing.allocator,
        config.engine,
        null,
        &catalog,
    );
    defer db_runtime.deinit();

    var registry = abi.ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerStaticModule("triage", &triage.manifest);
    try registry.registerStaticModule("ir", &ir.manifest);
    try registry.registerStaticModule("forensics", &forensics.manifest);

    var eng = pipeline_core.PipelineEngine.init(
        std.testing.allocator,
        &config,
        &catalog,
        &registry,
        &db_runtime,
    );
    defer eng.deinit();
    try eng.preflightValidate();

    var clean_mp4: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x11223344);
    prng.fill(&clean_mp4);
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    @memcpy(clean_mp4[0..mp4_hdr.len], mp4_hdr);
    // moov box (offset 24..32)
    @memcpy(clean_mp4[24..32], "\x00\x00\x00\x08moov");
    // mdat box (offset 32..8192): size = 8160 (0x1FE0)
    @memcpy(clean_mp4[32..40], "\x00\x00\x1F\xE0mdat");

    var artifacts = try pipeline_core.ArtifactStore.init(std.testing.allocator, &clean_mp4);
    defer artifacts.deinit();

    const summary = try eng.run(&artifacts);
    try std.testing.expectEqualStrings("video_verified_clean", summary.final_pipeline);

    var stmt = try db_runtime.db.prepareReadOnly(
        "SELECT file_size, detected_family, verdict, identified_format, mime_type FROM file_triage",
    );
    defer stmt.deinit();
    const row = (try stmt.step()).?;
    try std.testing.expectEqual(@as(i64, 8192), row.int64(0));
    try std.testing.expectEqualStrings("isobmff", row.text(1));
    try std.testing.expectEqualStrings("PASS", row.text(2));
    try std.testing.expectEqualStrings("mp4", row.text(3));
    try std.testing.expectEqualStrings("video/mp4", row.text(4));
}

test "E2E: configs/pipeline.yaml disguised ELF executable routes to quarantine_flow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schemas_bytes = try pipeline_core.readFileBytes(arena, "configs/schemas.yaml");
    const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schemas_bytes, null);

    const pipeline_bytes = try pipeline_core.readFileBytes(arena, "configs/pipeline.yaml");
    const config = try yaml_core.PipelineConfig.parse(arena, pipeline_bytes, null);

    var db_runtime = try sqlite_core.SqliteRuntime.initWithSettings(
        std.testing.allocator,
        config.engine,
        null,
        &catalog,
    );
    defer db_runtime.deinit();

    var registry = abi.ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerStaticModule("triage", &triage.manifest);
    try registry.registerStaticModule("ir", &ir.manifest);
    try registry.registerStaticModule("forensics", &forensics.manifest);

    var eng = pipeline_core.PipelineEngine.init(
        std.testing.allocator,
        &config,
        &catalog,
        &registry,
        &db_runtime,
    );
    defer eng.deinit();
    try eng.preflightValidate();

    var elf_spoof: [1024]u8 = @splat(0x90);
    @memcpy(elf_spoof[0..4], "\x7FELF");

    var artifacts = try pipeline_core.ArtifactStore.init(std.testing.allocator, &elf_spoof);
    defer artifacts.deinit();

    const summary = try eng.run(&artifacts);
    try std.testing.expectEqualStrings("quarantine_flow", summary.final_pipeline);

    var stmt = try db_runtime.db.prepareReadOnly(
        "SELECT rule_id, severity, region_tag FROM audit_findings WHERE rule_id = 'STAGE0_QUARANTINED'",
    );
    defer stmt.deinit();
    const row = (try stmt.step()).?;
    try std.testing.expectEqualStrings("STAGE0_QUARANTINED", row.text(0));
    try std.testing.expectEqual(@as(i64, 2), row.int64(1));
    try std.testing.expectEqualStrings("elf", row.text(2));
}

test "E2E: configs/pipeline.yaml overflowing mdat box triggers IR_REGION_OVERFLOW" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schemas_bytes = try pipeline_core.readFileBytes(arena, "configs/schemas.yaml");
    const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schemas_bytes, null);

    const pipeline_bytes = try pipeline_core.readFileBytes(arena, "configs/pipeline.yaml");
    const config = try yaml_core.PipelineConfig.parse(arena, pipeline_bytes, null);

    var db_runtime = try sqlite_core.SqliteRuntime.initWithSettings(
        std.testing.allocator,
        config.engine,
        null,
        &catalog,
    );
    defer db_runtime.deinit();

    var registry = abi.ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerStaticModule("triage", &triage.manifest);
    try registry.registerStaticModule("ir", &ir.manifest);
    try registry.registerStaticModule("forensics", &forensics.manifest);

    var eng = pipeline_core.PipelineEngine.init(
        std.testing.allocator,
        &config,
        &catalog,
        &registry,
        &db_runtime,
    );
    defer eng.deinit();
    try eng.preflightValidate();

    var overflow_mp4: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x55667788);
    prng.fill(&overflow_mp4);
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    @memcpy(overflow_mp4[0..mp4_hdr.len], mp4_hdr);
    @memcpy(overflow_mp4[24..32], "\x00\x00\x00\x08moov");
    // mdat declares 100,000 bytes (0x000186A0), far exceeding the 8192 bytes buffer!
    @memcpy(overflow_mp4[32..40], "\x00\x01\x86\xA0mdat");

    var artifacts = try pipeline_core.ArtifactStore.init(std.testing.allocator, &overflow_mp4);
    defer artifacts.deinit();

    const summary = try eng.run(&artifacts);
    try std.testing.expectEqualStrings("quarantine_flow", summary.final_pipeline);

    var stmt = try db_runtime.db.prepareReadOnly(
        "SELECT verdict FROM isobmff_triage",
    );
    defer stmt.deinit();
    const row = (try stmt.step()).?;
    try std.testing.expectEqualStrings("DROP", row.text(0));
}

test "E2E: configs/pipeline.yaml valid MPEG-TS stream routes to unsupported_format_flow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schemas_bytes = try pipeline_core.readFileBytes(arena, "configs/schemas.yaml");
    const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schemas_bytes, null);

    const pipeline_bytes = try pipeline_core.readFileBytes(arena, "configs/pipeline.yaml");
    const config = try yaml_core.PipelineConfig.parse(arena, pipeline_bytes, null);

    var db_runtime = try sqlite_core.SqliteRuntime.initWithSettings(
        std.testing.allocator,
        config.engine,
        null,
        &catalog,
    );
    defer db_runtime.deinit();

    var registry = abi.ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerStaticModule("triage", &triage.manifest);
    try registry.registerStaticModule("ir", &ir.manifest);
    try registry.registerStaticModule("forensics", &forensics.manifest);

    var eng = pipeline_core.PipelineEngine.init(
        std.testing.allocator,
        &config,
        &catalog,
        &registry,
        &db_runtime,
    );
    defer eng.deinit();
    try eng.preflightValidate();

    var ts_buf: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x13572468);
    prng.fill(&ts_buf);
    ts_buf[0] = 0x47;
    ts_buf[188] = 0x47;
    ts_buf[376] = 0x47;
    ts_buf[564] = 0x47;

    var artifacts = try pipeline_core.ArtifactStore.init(std.testing.allocator, &ts_buf);
    defer artifacts.deinit();

    const summary = try eng.run(&artifacts);
    try std.testing.expectEqualStrings("unsupported_format_flow", summary.final_pipeline);

    var stmt = try db_runtime.db.prepareReadOnly(
        "SELECT rule_id, severity, region_tag FROM audit_findings WHERE rule_id = 'STAGE1_UNSUPPORTED_FORMAT'",
    );
    defer stmt.deinit();
    const row = (try stmt.step()).?;
    try std.testing.expectEqualStrings("STAGE1_UNSUPPORTED_FORMAT", row.text(0));
    try std.testing.expectEqual(@as(i64, 1), row.int64(1));
    try std.testing.expectEqualStrings("mpeg_ts", row.text(2));
}

test "E2E: Pipeline execution on real sample bird.avi detects trailing overlay" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schemas_bytes = try pipeline_core.readFileBytes(arena, "configs/schemas.yaml");
    const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schemas_bytes, null);

    const pipeline_bytes = try pipeline_core.readFileBytes(arena, "configs/pipeline.yaml");
    const config = try yaml_core.PipelineConfig.parse(arena, pipeline_bytes, null);

    var db_runtime = try sqlite_core.SqliteRuntime.initWithSettings(
        std.testing.allocator,
        config.engine,
        null,
        &catalog,
    );
    defer db_runtime.deinit();

    var registry = abi.ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerStaticModule("triage", &triage.manifest);
    try registry.registerStaticModule("ir", &ir.manifest);
    try registry.registerStaticModule("forensics", &forensics.manifest);

    var eng = pipeline_core.PipelineEngine.init(
        std.testing.allocator,
        &config,
        &catalog,
        &registry,
        &db_runtime,
    );
    defer eng.deinit();
    try eng.preflightValidate();

    var artifacts = pipeline_core.ArtifactStore.initFromFile(std.testing.allocator, "bird.avi") catch |err| switch (err) {
        error.StreamNotFound => pipeline_core.ArtifactStore.initFromFile(std.testing.allocator, "zig-out/out/bird.avi") catch return,
        else => return err,
    };
    defer artifacts.deinit();

    const summary = try eng.run(&artifacts);
    try std.testing.expectEqualStrings("forensics_findings_detected", summary.final_pipeline);

    // Verify Stage 0 triage detected AVI
    var triage_stmt = try db_runtime.db.prepareReadOnly(
        "SELECT verdict, identified_format, mime_type FROM file_triage",
    );
    defer triage_stmt.deinit();
    const triage_row = (try triage_stmt.step()).?;
    try std.testing.expectEqualStrings("PASS", triage_row.text(0));
    try std.testing.expectEqualStrings("avi", triage_row.text(1));
    try std.testing.expectEqualStrings("video/x-msvideo", triage_row.text(2));

    // Verify R01_TRAILING_OVERLAY was detected by the forensics plugin
    var audit_stmt = try db_runtime.db.prepareReadOnly(
        "SELECT rule_id, severity FROM audit_findings WHERE rule_id = 'R01_TRAILING_OVERLAY'",
    );
    defer audit_stmt.deinit();
    const audit_row = (try audit_stmt.step()).?;
    try std.testing.expectEqualStrings("R01_TRAILING_OVERLAY", audit_row.text(0));
    try std.testing.expectEqual(@as(i64, 2), audit_row.int64(1));
}

test "E2E: Pipeline execution on real sample video.mp4 verifies clean" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schemas_bytes = try pipeline_core.readFileBytes(arena, "configs/schemas.yaml");
    const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schemas_bytes, null);

    const pipeline_bytes = try pipeline_core.readFileBytes(arena, "configs/pipeline.yaml");
    const config = try yaml_core.PipelineConfig.parse(arena, pipeline_bytes, null);

    var db_runtime = try sqlite_core.SqliteRuntime.initWithSettings(
        std.testing.allocator,
        config.engine,
        null,
        &catalog,
    );
    defer db_runtime.deinit();

    var registry = abi.ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerStaticModule("triage", &triage.manifest);
    try registry.registerStaticModule("ir", &ir.manifest);
    try registry.registerStaticModule("forensics", &forensics.manifest);

    var eng = pipeline_core.PipelineEngine.init(
        std.testing.allocator,
        &config,
        &catalog,
        &registry,
        &db_runtime,
    );
    defer eng.deinit();
    try eng.preflightValidate();

    var artifacts = pipeline_core.ArtifactStore.initFromFile(std.testing.allocator, "video.mp4") catch |err| switch (err) {
        error.StreamNotFound => pipeline_core.ArtifactStore.initFromFile(std.testing.allocator, "zig-out/out/video.mp4") catch return,
        else => return err,
    };
    defer artifacts.deinit();

    const summary = try eng.run(&artifacts);
    try std.testing.expectEqualStrings("video_verified_clean", summary.final_pipeline);

    var triage_stmt = try db_runtime.db.prepareReadOnly(
        "SELECT verdict, identified_format, mime_type FROM file_triage",
    );
    defer triage_stmt.deinit();
    const triage_row = (try triage_stmt.step()).?;
    try std.testing.expectEqualStrings("PASS", triage_row.text(0));
    try std.testing.expectEqualStrings("mp4", triage_row.text(1));
    try std.testing.expectEqualStrings("video/mp4", triage_row.text(2));
}
