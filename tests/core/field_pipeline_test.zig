const std = @import("std");
const vidsec = @import("vidsec");
const sqlite_core = vidsec.sqlite;
const pipeline = vidsec.pipeline;

const NamedValue = sqlite_core.NamedValue;
const Value = sqlite_core.Value;
const StorageRepository = pipeline.repository.StorageRepository;
const MemoryRepository = pipeline.repository.MemoryRepository;
const RepositoryRegistry = pipeline.repository.RepositoryRegistry;
const FieldRouter = pipeline.field_router.FieldRouter;
const OutputFieldSpec = pipeline.field_router.OutputFieldSpec;
const cursor_mod = pipeline.cursor;
const InputBinding = pipeline.InputBinding;
const TaskOutputStore = pipeline.TaskOutputStore;
const InputResolver = pipeline.InputResolver;

test "Pipeline: MemoryRepository stores and retrieves records in RAM with zero disk I/O" {
    const allocator = std.testing.allocator;

    var mem_repo = MemoryRepository.init(allocator);
    defer mem_repo.deinit();

    const storage = mem_repo.storageRepository();

    const record1 = [_]NamedValue{
        .{ .name = "region_id", .value = Value{ .int64 = 1 } },
        .{ .name = "tag", .value = Value{ .text = "ftyp" } },
        .{ .name = "offset", .value = Value{ .int64 = 0 } },
    };

    const record2 = [_]NamedValue{
        .{ .name = "region_id", .value = Value{ .int64 = 2 } },
        .{ .name = "tag", .value = Value{ .text = "moov" } },
        .{ .name = "offset", .value = Value{ .int64 = 24 } },
    };

    try storage.saveRecord("ir_regions", &record1);
    try storage.saveRecord("ir_regions", &record2);

    try std.testing.expectEqual(@as(usize, 2), storage.recordCount("ir_regions"));
    try std.testing.expectEqual(@as(usize, 0), storage.recordCount("non_existent"));

    const table = mem_repo.tables.get("ir_regions").?;
    try std.testing.expectEqualStrings("ftyp", table.records.items[0].fields[1].value.text);
    try std.testing.expectEqualStrings("moov", table.records.items[1].fields[1].value.text);
}

test "Pipeline: RepositoryRegistry registers and resolves multiple storage backends" {
    const allocator = std.testing.allocator;

    var registry = RepositoryRegistry.init(allocator);
    defer registry.deinit();

    var mem_repo = MemoryRepository.init(allocator);
    defer mem_repo.deinit();

    try registry.register("mem", mem_repo.storageRepository());

    const resolved = registry.get("mem");
    try std.testing.expect(resolved != null);
    try std.testing.expect(registry.get("non_existent") == null);
}

test "Pipeline: FieldRouter routes fields to memory and repo with renaming, casting, and math rounding" {
    const allocator = std.testing.allocator;

    var mem_repo = MemoryRepository.init(allocator);
    defer mem_repo.deinit();

    var persistent_repo = MemoryRepository.init(allocator);
    defer persistent_repo.deinit();

    var router = FieldRouter.init(allocator, "ir_regions");
    defer router.deinit();

    // 1. region_id -> to both memory and repo
    try router.addFieldSpec(.{
        .name = "region_id",
        .target = .both,
    });

    // 2. tag_name -> to both, renamed as 'tag'
    try router.addFieldSpec(.{
        .name = "tag_name",
        .target = .both,
        .as_name = "tag",
    });

    // 3. raw_buffer -> memory ONLY (does not touch persistent repo)
    try router.addFieldSpec(.{
        .name = "raw_buffer",
        .target = .memory,
    });

    // 4. calculated_bitrate -> cast from float to int, rounded
    try router.addFieldSpec(.{
        .name = "calculated_bitrate",
        .target = .both,
        .as_name = "bitrate_kbps",
        .cast = .int,
        .transform = .round,
    });

    // 5. entropy_score -> persistent repo ONLY, rounded to 2 decimal places
    try router.addFieldSpec(.{
        .name = "entropy_score",
        .target = .repo,
        .round_decimals = 2,
    });

    // Emitted record from a task
    const emitted_record = [_]NamedValue{
        .{ .name = "region_id", .value = Value{ .int64 = 101 } },
        .{ .name = "tag_name", .value = Value{ .text = "mdat" } },
        .{ .name = "raw_buffer", .value = Value{ .blob = "payload_sample_bytes" } },
        .{ .name = "calculated_bitrate", .value = Value{ .float64 = 2499.85 } },
        .{ .name = "entropy_score", .value = Value{ .float64 = 7.846192 } },
    };

    try router.dispatchRecord(
        &emitted_record,
        mem_repo.storageRepository(),
        persistent_repo.storageRepository(),
    );

    // Verify Memory Repository contents
    const mem_table = mem_repo.tables.get("ir_regions").?;
    try std.testing.expectEqual(@as(usize, 1), mem_table.records.items.len);
    const mem_fields = mem_table.records.items[0].fields;

    // Memory has 4 fields: region_id, tag, raw_buffer, bitrate_kbps (entropy_score excluded!)
    try std.testing.expectEqual(@as(usize, 4), mem_fields.len);
    try std.testing.expectEqualStrings("region_id", mem_fields[0].name);
    try std.testing.expectEqualStrings("tag", mem_fields[1].name);
    try std.testing.expectEqualStrings("raw_buffer", mem_fields[2].name);
    try std.testing.expectEqualStrings("bitrate_kbps", mem_fields[3].name);
    // Bitrate cast to int64: 2499.85 rounded -> 2500
    try std.testing.expectEqual(@as(i64, 2500), mem_fields[3].value.int64);

    // Verify Persistent Repository contents
    const repo_table = persistent_repo.tables.get("ir_regions").?;
    try std.testing.expectEqual(@as(usize, 1), repo_table.records.items.len);
    const repo_fields = repo_table.records.items[0].fields;

    // Repo has 4 fields: region_id, tag, bitrate_kbps, entropy_score (raw_buffer excluded to save space!)
    try std.testing.expectEqual(@as(usize, 4), repo_fields.len);
    try std.testing.expectEqualStrings("region_id", repo_fields[0].name);
    try std.testing.expectEqualStrings("tag", repo_fields[1].name);
    try std.testing.expectEqualStrings("bitrate_kbps", repo_fields[2].name);
    try std.testing.expectEqualStrings("entropy_score", repo_fields[3].name);
    // Entropy score rounded to 2 decimals: 7.846192 -> 7.85
    try std.testing.expectApproxEqAbs(@as(f64, 7.85), repo_fields[3].value.float64, 0.001);
}

test "MemoryCursor and RecordCursor provide zero-SQL iterator to plugins via ABI next_row and next_window" {
    var mem_repo = MemoryRepository.init(std.testing.allocator);
    defer mem_repo.deinit();

    // 1. Save records into memory repository
    const rec1 = [_]NamedValue{
        .{ .name = "window_id", .value = Value{ .int64 = 1 } },
        .{ .name = "file_offset", .value = Value{ .int64 = 100 } },
        .{ .name = "byte_length", .value = Value{ .int64 = 500 } },
        .{ .name = "region_tag", .value = Value{ .text = "moov" } },
    };
    const rec2 = [_]NamedValue{
        .{ .name = "window_id", .value = Value{ .int64 = 2 } },
        .{ .name = "file_offset", .value = Value{ .int64 = 600 } },
        .{ .name = "byte_length", .value = Value{ .int64 = 1200 } },
        .{ .name = "region_tag", .value = Value{ .text = "mdat" } },
    };
    try mem_repo.saveRecord("windows", &rec1);
    try mem_repo.saveRecord("windows", &rec2);

    const mem_tbl = mem_repo.tables.get("windows").?;
    try std.testing.expectEqual(@as(usize, 2), mem_tbl.records.items.len);

    // 2. Initialize MemoryCursor and wrap in RecordCursor
    const mem_cursor = cursor_mod.MemoryCursor.init("file", mem_tbl.records.items);
    var record_cursor = cursor_mod.RecordCursor{ .memory = mem_cursor };
    defer record_cursor.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("file", record_cursor.streamSource().?);

    // 3. Plugin consumes rows via nextRow (zero SQLite)
    const row1 = (try record_cursor.nextRow(std.testing.allocator)).?;
    try std.testing.expectEqual(@as(usize, 4), row1.fields_len);
    try std.testing.expectEqual(@as(i64, 1), row1.getField("window_id").?.asInt().?);
    try std.testing.expectEqual(@as(i64, 100), row1.getField("file_offset").?.asInt().?);
    try std.testing.expectEqualStrings("moov", row1.getField("region_tag").?.asText().?);

    const row2 = (try record_cursor.nextRow(std.testing.allocator)).?;
    try std.testing.expectEqual(@as(i64, 2), row2.getField("window_id").?.asInt().?);
    try std.testing.expectEqual(@as(i64, 600), row2.getField("file_offset").?.asInt().?);
    try std.testing.expectEqualStrings("mdat", row2.getField("region_tag").?.asText().?);

    // Exhausted
    const row3 = try record_cursor.nextRow(std.testing.allocator);
    try std.testing.expect(row3 == null);

    // 4. Test nextWindow
    var win_cursor = cursor_mod.RecordCursor{
        .memory = cursor_mod.MemoryCursor.init("file", mem_tbl.records.items),
    };
    defer win_cursor.deinit(std.testing.allocator);

    const w1 = (try win_cursor.nextWindow()).?;
    try std.testing.expectEqual(@as(i64, 1), w1.window_id);
    try std.testing.expectEqual(@as(u64, 100), w1.file_offset);
    try std.testing.expectEqual(@as(u64, 500), w1.byte_length);
    try std.testing.expectEqualStrings("moov", w1.tagSlice());

    const w2 = (try win_cursor.nextWindow()).?;
    try std.testing.expectEqual(@as(i64, 2), w2.window_id);
    try std.testing.expectEqual(@as(u64, 600), w2.file_offset);
    try std.testing.expectEqual(@as(u64, 1200), w2.byte_length);
    try std.testing.expectEqualStrings("mdat", w2.tagSlice());

    const w3 = try win_cursor.nextWindow();
    try std.testing.expect(w3 == null);
}

test "InputBinding and InputResolver: resolve values from previous task outputs with transform, cast, and defaults" {
    var task_outputs = TaskOutputStore.init(std.testing.allocator);
    defer task_outputs.deinit();

    // Task "parse_container" emits some fields
    try task_outputs.recordField("parse_container", "file_size", Value{ .int64 = 1048576 });
    try task_outputs.recordField("parse_container", "calculated_bitrate", Value{ .float64 = 2499.854 });
    try task_outputs.recordField("parse_container", "raw_flag", Value{ .text = "true" });

    var mem_repo = MemoryRepository.init(std.testing.allocator);
    defer mem_repo.deinit();

    const resolver = InputResolver.init(&task_outputs, &mem_repo, null, null);

    // 1. Direct binding: parse_container.file_size
    const b1 = InputBinding{ .from_path = "parse_container.file_size" };
    const v1 = try resolver.resolveValue(std.testing.allocator, b1);
    try std.testing.expectEqual(@as(i64, 1048576), v1.int64);

    // 2. Transform + cast: round 2499.854 -> 2500 -> cast to int
    const b2 = InputBinding{
        .from_path = "parse_container.calculated_bitrate",
        .transform = .round,
        .cast = .int,
    };
    const v2 = try resolver.resolveValue(std.testing.allocator, b2);
    try std.testing.expectEqual(@as(i64, 2500), v2.int64);

    // 3. Cast text to boolean: "true" -> true
    const b3 = InputBinding{
        .from_path = "parse_container.raw_flag",
        .cast = .boolean,
    };
    const v3 = try resolver.resolveValue(std.testing.allocator, b3);
    try std.testing.expectEqual(true, v3.boolean);

    // 4. Missing value with default fallback
    const b4 = InputBinding{
        .from_path = "parse_container.nonexistent_field",
        .default_val = Value{ .int64 = 42 },
    };
    const v4 = try resolver.resolveValue(std.testing.allocator, b4);
    try std.testing.expectEqual(@as(i64, 42), v4.int64);

    // 5. Missing value without default returns error
    const b5 = InputBinding{
        .from_path = "parse_container.another_missing",
    };
    try std.testing.expectError(error.MissingBoundInputValue, resolver.resolveValue(std.testing.allocator, b5));
}

test "InputBinding: YAML parsing of shorthand and expanded declarations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const yaml_input =
        \\file_size: parse_container.file_size
        \\bitrate:
        \\  from: parse_container.calculated_bitrate
        \\  transform: round
        \\  cast: int
        \\  default: 0
        \\entropy:
        \\  from: parse_container.entropy
        \\  transform: round_decimals(2)
    ;

    const yaml_lib = vidsec.yaml.yaml_lib;
    const MapType = yaml_lib.Map(InputBinding);
    const parsed_map = try yaml_lib.parse(MapType, arena, yaml_input, .{});

    // Verify shorthand parsed
    const b_size = parsed_map.get("file_size").?;
    try std.testing.expectEqualStrings("parse_container.file_size", b_size.from_path);
    try std.testing.expectEqual(@as(@TypeOf(b_size.transform), .none), b_size.transform);

    // Verify expanded parsed
    const b_bitrate = parsed_map.get("bitrate").?;
    try std.testing.expectEqualStrings("parse_container.calculated_bitrate", b_bitrate.from_path);
    try std.testing.expectEqual(@as(@TypeOf(b_bitrate.transform), .round), b_bitrate.transform);
    try std.testing.expectEqual(@as(@TypeOf(b_bitrate.cast), .int), b_bitrate.cast);
    try std.testing.expectEqual(@as(i64, 0), b_bitrate.default_val.?.int64);

    // Verify round_decimals(2) parsed
    const b_entropy = parsed_map.get("entropy").?;
    try std.testing.expectEqualStrings("parse_container.entropy", b_entropy.from_path);
    try std.testing.expectEqual(@as(?u8, 2), b_entropy.round_decimals);
}

test "PipelineConfig: Natural YAML syntax with storages, id/uses, persist, and inputs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pipeline_yaml =
        \\version: 2
        \\
        \\storages:
        \\  db:
        \\    type: sqlite
        \\    schema: "./configs/schemas.yaml"
        \\    path: "./vidsec_state.db"
        \\  artifacts:
        \\    type: file_store
        \\    directory: "./artifacts/"
        \\
        \\modules:
        \\  analyzer:
        \\    path: "./zig-out/lib/libanalyzer.so"
        \\
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: audit_container
        \\        uses: analyzer/probe_isobmff
        \\        inputs:
        \\          file_path: target.file_path
        \\          file_size: probe_l0.file_size
        \\        params:
        \\          allow_gaps: false
        \\          max_gap_tolerance_bytes: 0
        \\          allow_trailing_data: false
        \\          max_depth: 8
        \\          strict_order: true
        \\        persist:
        \\          db: isobmff_triage
        \\
        \\      - id: analyze_topology
        \\        uses: analyzer/ir_topology
        \\        inputs:
        \\          file_size: audit_container.file_size
        \\          prev_verdict: db.file_triage.verdict
        \\          raw_buffer: artifacts.quarantine_sample
        \\          frame_rate:
        \\            from: audit_container.fps
        \\            cast: int
        \\          bitrate_kbps:
        \\            from: audit_container.calculated_bitrate
        \\            transform: round
        \\            cast: int
        \\          entropy_score:
        \\            from: db.isobmff_triage.entropy
        \\            transform: round_decimals(2)
        \\          track_count:
        \\            from: audit_container.audio_tracks
        \\            default: 0
        \\        output:
        \\          persist: db.audit_findings
    ;

    const config = try vidsec.yaml.PipelineConfig.parse(arena, pipeline_yaml, null);

    // Verify version and storages/engine
    try std.testing.expectEqual(@as(u32, 2), config.version);
    try std.testing.expectEqualStrings("./configs/schemas.yaml", config.engine.schemas_path);
    try std.testing.expectEqualStrings("./vidsec_state.db", config.engine.db_path.?);
    try std.testing.expectEqual(vidsec.yaml.DbMode.wal_file, config.engine.db_mode);

    const main_steps = config.pipelines.get("main").?.steps;
    try std.testing.expectEqual(@as(usize, 2), main_steps.len);

    // Verify Step 1: audit_container
    const step1 = main_steps[0].task;
    try std.testing.expectEqualStrings("audit_container", step1.name);
    try std.testing.expectEqualStrings("analyzer", step1.target.module_task.module);
    try std.testing.expectEqualStrings("probe_isobmff", step1.target.module_task.task);
    try std.testing.expect(step1.output != null);
    try std.testing.expectEqualStrings("isobmff_triage", step1.output.?.into.?);
    try std.testing.expectEqual(false, step1.getParam("allow_gaps").?.boolean);
    try std.testing.expectEqual(@as(i64, 8), step1.getParam("max_depth").?.int64);

    // Verify Step 2: analyze_topology
    const step2 = main_steps[1].task;
    try std.testing.expectEqualStrings("analyze_topology", step2.name);
    try std.testing.expectEqualStrings("analyzer", step2.target.module_task.module);
    try std.testing.expectEqualStrings("ir_topology", step2.target.module_task.task);
    try std.testing.expect(step2.output != null);
    try std.testing.expectEqualStrings("audit_findings", step2.output.?.into.?);

    // Verify bindings on step 2
    const b_size = step2.getInputBinding("file_size").?;
    try std.testing.expectEqualStrings("audit_container.file_size", b_size.from_path);

    const b_verdict = step2.getInputBinding("prev_verdict").?;
    try std.testing.expectEqualStrings("db.file_triage.verdict", b_verdict.from_path);

    const b_raw = step2.getInputBinding("raw_buffer").?;
    try std.testing.expectEqualStrings("artifacts.quarantine_sample", b_raw.from_path);

    const b_bitrate = step2.getInputBinding("bitrate_kbps").?;
    try std.testing.expectEqual(@as(@TypeOf(b_bitrate.transform), .round), b_bitrate.transform);
    try std.testing.expectEqual(@as(@TypeOf(b_bitrate.cast), .int), b_bitrate.cast);

    const b_entropy = step2.getInputBinding("entropy_score").?;
    try std.testing.expectEqual(@as(?u8, 2), b_entropy.round_decimals);

    const b_tracks = step2.getInputBinding("track_count").?;
    try std.testing.expectEqual(@as(i64, 0), b_tracks.default_val.?.int64);
}

test "Router: In-memory condition evaluation without SQLite roundtrips" {
    const allocator = std.testing.allocator;

    var mem_repo = MemoryRepository.init(allocator);
    defer mem_repo.deinit();

    var task_outputs = TaskOutputStore.init(allocator);
    defer task_outputs.deinit();

    // Populate task outputs from probe_file in memory
    const fields = [_]NamedValue{
        .{ .name = "detected_family", .value = Value{ .text = "isobmff" } },
        .{ .name = "verdict", .value = Value{ .int64 = 0 } }, // PASS = 0
        .{ .name = "true_magic_kind", .value = Value{ .int64 = 0 } },
        .{ .name = "exceeds_size_limit", .value = Value{ .boolean = false } },
    };
    try task_outputs.recordRecord("stage0_probe_file", &fields);

    const resolver = InputResolver.init(&task_outputs, &mem_repo, null, null);

    // Test format triage routing in memory
    const cond_isobmff = "stage0_probe_file.detected_family == 'isobmff'";
    try std.testing.expect(pipeline.router.evaluateCondition(allocator, cond_isobmff, &resolver));

    const cond_ebml = "stage0_probe_file.detected_family == 'ebml'";
    try std.testing.expect(!pipeline.router.evaluateCondition(allocator, cond_ebml, &resolver));

    // Test triage verdict routing in memory (clean sample -> not dropped)
    const cond_drop = "stage0_probe_file.verdict == 'DROP' or stage0_probe_file.true_magic_kind >= 10 or stage0_probe_file.exceeds_size_limit == 1";
    try std.testing.expect(!pipeline.router.evaluateCondition(allocator, cond_drop, &resolver));

    // Test drop sample
    const drop_fields = [_]NamedValue{
        .{ .name = "verdict", .value = Value{ .int64 = 2 } }, // DROP = 2
        .{ .name = "true_magic_kind", .value = Value{ .int64 = 12 } },
        .{ .name = "exceeds_size_limit", .value = Value{ .boolean = true } },
    };
    try task_outputs.recordRecord("malicious_probe", &drop_fields);

    const cond_malicious = "malicious_probe.verdict == 'DROP' or malicious_probe.true_magic_kind >= 10 or malicious_probe.exceeds_size_limit == 1";
    try std.testing.expect(pipeline.router.evaluateCondition(allocator, cond_malicious, &resolver));
}

test "Pipeline: Declarative outputs with field-level routing into db and memory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pipeline_yaml =
        \\version: 2
        \\storages:
        \\  db:
        \\    type: sqlite
        \\    schema: "./configs/schemas.yaml"
        \\    path: "./vidsec_state.db"
        \\
        \\modules:
        \\  analyzer:
        \\    path: "./zig-out/lib/libanalyzer.so"
        \\
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: stage0_probe
        \\        uses: analyzer/probe_file
        \\        params:
        \\          min_file_size_bytes: 8
        \\        outputs:
        \\          into: file_triage
        \\          fields:
        \\            verdict:
        \\              into: db
        \\            file_size:
        \\              into: db
        \\            raw_entropy:
        \\              into: memory
        \\            calculated_bitrate:
        \\              into: db
        \\              as: bitrate_kbps
        \\              transform: round
        \\              cast: int
        \\
        \\      - id: lower_pure_memory
        \\        uses: analyzer/lower_mp4_media
        \\        outputs:
        \\          target: memory
    ;

    const config = try vidsec.yaml.PipelineConfig.parse(arena, pipeline_yaml, null);
    const main_steps = config.pipelines.get("main").?.steps;
    try std.testing.expectEqual(@as(usize, 2), main_steps.len);

    const step1 = main_steps[0].task;
    try std.testing.expectEqualStrings("stage0_probe", step1.name);
    try std.testing.expect(step1.output != null);
    try std.testing.expectEqualStrings("file_triage", step1.output.?.into.?);

    const fs = step1.output.?.field_specs;
    try std.testing.expectEqual(@as(usize, 4), fs.count());

    const v_spec = fs.get("verdict").?;
    try std.testing.expectEqual(pipeline.field_router.field_target.TargetDestination.repo, v_spec.target);

    const raw_spec = fs.get("raw_entropy").?;
    try std.testing.expectEqual(pipeline.field_router.field_target.TargetDestination.memory, raw_spec.target);

    const br_spec = fs.get("calculated_bitrate").?;
    try std.testing.expectEqual(pipeline.field_router.field_target.TargetDestination.repo, br_spec.target);
    try std.testing.expectEqualStrings("bitrate_kbps", br_spec.as_name.?);
    try std.testing.expectEqual(pipeline.field_router.field_transform.FieldTransform.round, br_spec.transform);
    try std.testing.expectEqual(pipeline.field_router.field_cast.FieldCast.int, br_spec.cast);

    const step2 = main_steps[1].task;
    try std.testing.expectEqualStrings("lower_pure_memory", step2.name);
    try std.testing.expect(step2.output != null);
    try std.testing.expectEqual(pipeline.field_router.field_target.TargetDestination.memory, step2.output.?.target_dest.?);
}

test "Pipeline: Declarative multi-table outputs with sequence syntax" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pipeline_yaml =
        \\version: 2
        \\engine:
        \\  schemas: ./configs/schemas.yaml
        \\modules:
        \\  analyzer:
        \\    path: ./zig-out/lib/libanalyzer.so
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: lower_container
        \\        uses: analyzer/lower_isobmff_container
        \\        outputs:
        \\          into: [container_metadata, ir_regions, audit_findings]
    ;

    const config = try vidsec.yaml.PipelineConfig.parse(arena, pipeline_yaml, null);
    const main_steps = config.pipelines.get("main").?.steps;
    try std.testing.expectEqual(@as(usize, 1), main_steps.len);

    const step = main_steps[0].task;
    try std.testing.expect(step.output != null);
    try std.testing.expectEqualStrings("container_metadata", step.output.?.into.?);
    try std.testing.expect(step.output.?.tables != null);
    try std.testing.expectEqual(@as(usize, 3), step.output.?.tables.?.len);
    try std.testing.expectEqualStrings("container_metadata", step.output.?.tables.?[0]);
    try std.testing.expectEqualStrings("ir_regions", step.output.?.tables.?[1]);
    try std.testing.expectEqualStrings("audit_findings", step.output.?.tables.?[2]);
}
