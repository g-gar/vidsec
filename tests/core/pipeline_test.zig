const std = @import("std");
const vidsec = @import("vidsec");
const abi_lib = @import("vidsec_abi");

const yaml_core = vidsec.yaml;
const sqlite_core = vidsec.sqlite;
const PipelineEngine = vidsec.pipeline.PipelineEngine;
const ArtifactStore = vidsec.pipeline.ArtifactStore;

test "Domain-agnostic PipelineEngine: C-ABI tasks, lazy windows, row cursors, sql_rule, routers, artifacts, and JSONL trace" {
    const schemas_yaml =
        \\version: 2
        \\schemas:
        \\  ingest_dom:
        \\    records:
        \\      columns:
        \\        record_id: { type: int64 }
        \\        category:  { type: text }
        \\        priority:  { type: int64 }
        \\  analytics_dom:
        \\    summary:
        \\      columns:
        \\        total_bytes:   { type: int64 }
        \\        cutoff_offset: { type: int64 }
        \\    segments:
        \\      columns:
        \\        segment_id:  { type: int64, pk: true }
        \\        label:       { type: text }
        \\        kind:        { type: text }
        \\        head_offset: { type: int64 }
        \\        body_offset: { type: int64 }
        \\        tail_offset: { type: int64 }
        \\  reports_dom:
        \\    alerts:
        \\      columns:
        \\        alert_id: { type: int64, pk: true }
        \\        code:     { type: text }
        \\        level:    { type: int64 }
        \\        offset:   { type: int64 }
        \\        label:    { type: text, nullable: true }
        \\        score:    { type: float64, nullable: true }
        \\        details:  { type: text, nullable: true }
    ;

    const pipeline_yaml =
        \\version: 2
        \\engine:
        \\  schemas: "./schemas.yaml"
        \\  db_mode: memory
        \\modules:
        \\  ingest:   { path: "./plugins/libingest.so" }
        \\  analyzer: { path: "./plugins/libanalyzer.so" }
        \\  scanner:  { path: "./plugins/libscanner.so" }
        \\  modifier: { path: "./plugins/libmodifier.so" }
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - task: ingest_header
        \\        use: ingest/parse_header
        \\        input:
        \\          stream: { from: file }
        \\        output:
        \\          into: records
        \\          map:
        \\            record_id: record_id
        \\            category: category
        \\            priority: priority
        \\      - router: check_category
        \\        cases:
        \\          - when: "SELECT 1 FROM records WHERE category = 'batch'"
        \\            goto: batch_flow
        \\        default: exit
        \\  batch_flow:
        \\    steps:
        \\      - task: decompose_segments
        \\        use: analyzer/decompose
        \\        input:
        \\          stream: { from: file }
        \\        output:
        \\          schema: analytics_dom
        \\      - task: check_overflow_rule
        \\        use: sql_rule
        \\        query: |
        \\          SELECT 'OVERFLOW_RULE' AS code, 1 AS level, cutoff_offset AS offset,
        \\                 'OVERFLOW' AS label, 'Trailing excess data detected' AS details
        \\          FROM summary WHERE total_bytes > cutoff_offset
        \\        output:
        \\          into: alerts
        \\      - task: scan_segments
        \\        use: scanner/pattern_scan
        \\        input:
        \\          windows:
        \\            from: file
        \\            table: segments
        \\            filter: "kind = 'padding'"
        \\            map:
        \\              id: segment_id
        \\              offset: body_offset
        \\              length: "tail_offset - body_offset"
        \\              tag: label
        \\        params:
        \\          score_threshold: 7.0
        \\        output:
        \\          into: alerts
        \\          map:
        \\            code: "'PATTERN_MATCH'"
        \\            offset: offset
        \\            label: tag
        \\            level: level
        \\            score: score
        \\      - task: clean_artifact
        \\        use: modifier/clean_artifact
        \\        input:
        \\          stream: { from: file }
        \\          windows:
        \\            from: file
        \\            table: segments
        \\            filter: "kind = 'padding'"
        \\            map:
        \\              id: segment_id
        \\              offset: body_offset
        \\              length: "tail_offset - body_offset"
        \\              tag: label
        \\          meta:
        \\            table: summary
        \\            map:
        \\              cutoff_offset: cutoff_offset
        \\        output:
        \\          artifact: cleaned_data
    ;

    // Define mock C-ABI plugins using `src/lib/abi/sdk.zig`
    const Plugins = struct {
        fn runParseHeader(ctx: abi_lib.TaskContext) !abi_lib.TaskStatus_ABI {
            const sz = ctx.streamSize();
            var hdr: [4]u8 = undefined;
            try ctx.streamReadAt(0, &hdr);
            const cat = if (std.mem.eql(u8, &hdr, "HEAD")) "batch" else "single";
            try ctx.emitRow(null, &.{
                abi_lib.NamedField_ABI.init("record_id", abi_lib.Value_ABI.fromInt(@intCast(sz))),
                abi_lib.NamedField_ABI.init("category", abi_lib.Value_ABI.fromText(cat)),
                abi_lib.NamedField_ABI.init("priority", abi_lib.Value_ABI.fromInt(1)),
            });
            return .ok;
        }

        fn runDecompose(ctx: abi_lib.TaskContext) !abi_lib.TaskStatus_ABI {
            const sz = ctx.streamSize();
            try ctx.emitRow("summary", &.{
                abi_lib.NamedField_ABI.init("total_bytes", abi_lib.Value_ABI.fromInt(@intCast(sz))),
                abi_lib.NamedField_ABI.init("cutoff_offset", abi_lib.Value_ABI.fromInt(20)),
            });
            // Emit 1 primary segment [0..12) and 1 padding segment [12..20)
            try ctx.emitRow("segments", &.{
                abi_lib.NamedField_ABI.init("segment_id", abi_lib.Value_ABI.fromInt(1)),
                abi_lib.NamedField_ABI.init("label", abi_lib.Value_ABI.fromText("head_data")),
                abi_lib.NamedField_ABI.init("kind", abi_lib.Value_ABI.fromText("primary")),
                abi_lib.NamedField_ABI.init("head_offset", abi_lib.Value_ABI.fromInt(0)),
                abi_lib.NamedField_ABI.init("body_offset", abi_lib.Value_ABI.fromInt(4)),
                abi_lib.NamedField_ABI.init("tail_offset", abi_lib.Value_ABI.fromInt(12)),
            });
            try ctx.emitRow("segments", &.{
                abi_lib.NamedField_ABI.init("segment_id", abi_lib.Value_ABI.fromInt(2)),
                abi_lib.NamedField_ABI.init("label", abi_lib.Value_ABI.fromText("pad_data")),
                abi_lib.NamedField_ABI.init("kind", abi_lib.Value_ABI.fromText("padding")),
                abi_lib.NamedField_ABI.init("head_offset", abi_lib.Value_ABI.fromInt(12)),
                abi_lib.NamedField_ABI.init("body_offset", abi_lib.Value_ABI.fromInt(14)),
                abi_lib.NamedField_ABI.init("tail_offset", abi_lib.Value_ABI.fromInt(20)),
            });
            return .ok;
        }

        fn runPatternScan(ctx: abi_lib.TaskContext) !abi_lib.TaskStatus_ABI {
            // Task only declared `input: { windows: ... }` in YAML, NOT `stream:`.
            // Attempting raw stream access must be blocked with `error.PermissionDenied`!
            var forbidden_buf: [4]u8 = undefined;
            try std.testing.expectError(error.PermissionDenied, ctx.streamReadAt(0, &forbidden_buf));
            try std.testing.expectEqual(@as(u64, 0), ctx.streamSize());

            const threshold = try ctx.getParamFloat("score_threshold", 7.2);
            while (try ctx.nextWindow()) |win| {
                var buf: [6]u8 = undefined;
                try ctx.windowReadAt(&win, 0, buf[0..@intCast(win.byte_length)]);
                if (std.mem.eql(u8, buf[0..@intCast(win.byte_length)], "SECRET")) {
                    try ctx.emitRow(null, &.{
                        abi_lib.NamedField_ABI.init("offset", abi_lib.Value_ABI.fromInt(@intCast(win.file_offset))),
                        abi_lib.NamedField_ABI.init("tag", abi_lib.Value_ABI.fromText(win.tagSlice())),
                        abi_lib.NamedField_ABI.init("level", abi_lib.Value_ABI.fromInt(2)),
                        abi_lib.NamedField_ABI.init("score", abi_lib.Value_ABI.fromFloat(threshold + 0.5)),
                    });
                }
            }
            ctx.logInfo("Scanned target windows");
            return .ok;
        }

        fn runCleanArtifact(ctx: abi_lib.TaskContext) !abi_lib.TaskStatus_ABI {
            while (try ctx.nextWindow()) |win| {
                _ = try ctx.carveToQuarantine(win.file_offset, win.byte_length, "QUARANTINE_PAD");
                try ctx.artifactZeroRange(win.file_offset, win.byte_length);
            }
            if (try ctx.nextRow("meta")) |row| {
                if (row.getField("cutoff_offset")) |v| {
                    try ctx.artifactTruncate(@intCast(v.asInt().?));
                }
            }
            return .ok;
        }

        const ingest_tasks = [_]abi_lib.TaskDescriptor_ABI{
            abi_lib.defineTask(.{
                .name = "parse_header",
                .output_fields = &.{ "record_id", "category", "priority" },
                .run = &runParseHeader,
            }),
        };
        const ingest_manifest = abi_lib.defineManifest("ingest", .{ .major = 2, .minor = 0, .patch = 0 }, &ingest_tasks);

        const analyzer_tasks = [_]abi_lib.TaskDescriptor_ABI{
            abi_lib.defineTask(.{
                .name = "decompose",
                .run = &runDecompose,
            }),
        };
        const analyzer_manifest = abi_lib.defineManifest("analyzer", .{ .major = 2, .minor = 0, .patch = 0 }, &analyzer_tasks);

        const scanner_tasks = [_]abi_lib.TaskDescriptor_ABI{
            abi_lib.defineTask(.{
                .name = "pattern_scan",
                .output_fields = &.{ "offset", "tag", "level", "score" },
                .required_params = &.{"score_threshold"},
                .run = &runPatternScan,
            }),
        };
        const scanner_manifest = abi_lib.defineManifest("scanner", .{ .major = 2, .minor = 0, .patch = 0 }, &scanner_tasks);

        const modifier_tasks = [_]abi_lib.TaskDescriptor_ABI{
            abi_lib.defineTask(.{
                .name = "clean_artifact",
                .run = &runCleanArtifact,
            }),
        };
        const modifier_manifest = abi_lib.defineManifest("modifier", .{ .major = 2, .minor = 0, .patch = 0 }, &modifier_tasks);
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schemas_yaml, null);
    const config = try yaml_core.PipelineConfig.parse(arena, pipeline_yaml, null);

    var registry = vidsec.pipeline.ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerStaticModule("ingest", &Plugins.ingest_manifest);
    try registry.registerStaticModule("analyzer", &Plugins.analyzer_manifest);
    try registry.registerStaticModule("scanner", &Plugins.scanner_manifest);
    try registry.registerStaticModule("modifier", &Plugins.modifier_manifest);

    var db_runtime = try sqlite_core.SqliteRuntime.initMemory(std.testing.allocator, &catalog);
    defer db_runtime.deinit();

    var p_engine = PipelineEngine.init(
        std.testing.allocator,
        &config,
        &catalog,
        &registry,
        &db_runtime,
    );
    defer p_engine.deinit();

    // 1. Pre-flight validation must pass
    try p_engine.preflightValidate();

    // 2. Prepare 24-byte input stream:
    //    [0..12) = "HEAD_PAYLOAD"
    //    [12..14) = "XX"
    //    [14..20) = "SECRET" (target window)
    //    [20..24) = "OVLY"   (trailing overflow)
    const input_bytes = "HEAD_PAYLOADXXSECRETOVLY";
    var artifacts = try ArtifactStore.init(std.testing.allocator, input_bytes);
    defer artifacts.deinit();

    // 3. Execute pipeline
    const summary = try p_engine.run(&artifacts);
    try std.testing.expectEqual(@as(usize, 5), summary.steps_executed);
    try std.testing.expectEqual(@as(usize, 1), summary.routers_evaluated);
    try std.testing.expect(!summary.halted_early);
    try std.testing.expectEqualStrings("batch_flow", summary.final_pipeline);

    // 4. Verify SQLite findings (OVERFLOW_RULE from sql_rule + PATTERN_MATCH from pattern_scan)
    var stmt = try db_runtime.db.prepareReadOnly("SELECT code, offset, level FROM alerts ORDER BY code");
    defer stmt.deinit();

    const row1 = (try stmt.step()).?;
    try std.testing.expectEqualStrings("OVERFLOW_RULE", row1.text(0));
    try std.testing.expectEqual(@as(i64, 20), row1.int64(1));

    const row2 = (try stmt.step()).?;
    try std.testing.expectEqualStrings("PATTERN_MATCH", row2.text(0));
    try std.testing.expectEqual(@as(i64, 14), row2.int64(1));
    try std.testing.expectEqual(@as(i64, 2), row2.int64(2));

    // 5. Verify carved quarantine evidence & sanitized artifact
    try std.testing.expectEqual(@as(usize, 1), artifacts.carved_items.items.len);
    try std.testing.expectEqualStrings("SECRET", artifacts.carved_items.items[0].data);

    const cleaned = try artifacts.getBuffer("cleaned_data");
    // Truncated to 20 bytes and bytes [14..20) zeroed out!
    try std.testing.expectEqual(@as(u64, 20), cleaned.size());
    try std.testing.expectEqualStrings("HEAD_PAYLOADXX\x00\x00\x00\x00\x00\x00", cleaned.slice());

    // 6. Verify structured JSONL trace output
    const jsonl = try p_engine.tracer.toJsonLines(std.testing.allocator);
    defer std.testing.allocator.free(jsonl);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"event\":\"router_decision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"message\":\"Scanned target windows\"") != null);
}

test "Pre-flight validation catches undeclared plugin output fields and SAVEPOINT rolls back on fatal_error" {
    const schemas_yaml =
        \\version: 2
        \\schemas:
        \\  monitoring:
        \\    metrics:
        \\      columns:
        \\        metric_id: { type: int64, pk: true }
        \\        name:      { type: text }
        \\        level:     { type: int64 }
        \\        offset:    { type: int64 }
    ;

    const bad_map_yaml =
        \\version: 2
        \\engine:
        \\  schemas: "./schemas.yaml"
        \\modules:
        \\  processors: { path: "./plugins/libprocessors.so" }
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - task: bad_step
        \\        use: processors/process
        \\        params:
        \\          threshold: 5
        \\        output:
        \\          into: metrics
        \\          map:
        \\            name: "'ALERT_SAMPLE'"
        \\            level: level
        \\            offset: typo_nonexistent_field
    ;

    const TestPlugin = struct {
        fn runFailingTask(ctx: abi_lib.TaskContext) !abi_lib.TaskStatus_ABI {
            // Emit one row into SQLite, then fail fatally -> must be rolled back by SAVEPOINT!
            try ctx.emitRow(null, &.{
                abi_lib.NamedField_ABI.init("level", abi_lib.Value_ABI.fromInt(2)),
                abi_lib.NamedField_ABI.init("offset", abi_lib.Value_ABI.fromInt(128)),
            });
            return .fatal_error;
        }

        const tasks = [_]abi_lib.TaskDescriptor_ABI{
            abi_lib.defineTask(.{
                .name = "process",
                .output_fields = &.{ "level", "offset" },
                .required_params = &.{"threshold"},
                .run = &runFailingTask,
            }),
        };
        const manifest = abi_lib.defineManifest("processors", .{ .major = 2, .minor = 0, .patch = 0 }, &tasks);
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schemas_yaml, null);
    const bad_config = try yaml_core.PipelineConfig.parse(arena, bad_map_yaml, null);

    var registry = vidsec.pipeline.ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerStaticModule("processors", &TestPlugin.manifest);

    var db_runtime = try sqlite_core.SqliteRuntime.initMemory(std.testing.allocator, &catalog);
    defer db_runtime.deinit();

    var bad_engine = PipelineEngine.init(std.testing.allocator, &bad_config, &catalog, &registry, &db_runtime);
    defer bad_engine.deinit();

    try std.testing.expectError(error.UndeclaredPluginOutputField, bad_engine.preflightValidate());

    // Now fix the field name in YAML and verify SAVEPOINT rollback when the task returns `.fatal_error`
    const valid_yaml =
        \\version: 2
        \\engine:
        \\  schemas: "./schemas.yaml"
        \\modules:
        \\  processors: { path: "./plugins/libprocessors.so" }
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - task: failing_step
        \\        use: processors/process
        \\        params:
        \\          threshold: 5
        \\        output:
        \\          into: metrics
        \\          map:
        \\            name: "'ALERT_SAMPLE'"
        \\            level: level
        \\            offset: offset
    ;

    const valid_config = try yaml_core.PipelineConfig.parse(arena, valid_yaml, null);
    var p_engine = PipelineEngine.init(std.testing.allocator, &valid_config, &catalog, &registry, &db_runtime);
    defer p_engine.deinit();

    try p_engine.preflightValidate();

    var artifacts = try ArtifactStore.init(std.testing.allocator, "DUMMY");
    defer artifacts.deinit();

    try std.testing.expectError(error.TaskFatalError, p_engine.run(&artifacts));

    // Verify the row emitted prior to `.fatal_error` was rolled back by SAVEPOINT
    var stmt = try db_runtime.db.prepareReadOnly("SELECT COUNT(*) FROM metrics");
    defer stmt.deinit();
    const row = (try stmt.step()).?;
    try std.testing.expectEqual(@as(i64, 0), row.int64(0));
}
