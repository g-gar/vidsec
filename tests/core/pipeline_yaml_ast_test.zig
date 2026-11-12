const std = @import("std");
const vidsec = @import("vidsec");
const yaml_mod = vidsec.yaml;
const ast_mod = vidsec.pipeline_ast;

test "YAML to AST: Declarative pipeline with open datasources, router, and steps" {
    const yaml_text =
        \\version: 2
        \\runtime:
        \\  workers: 4
        \\datasources:
        \\  pipeline_memory:
        \\    type: memory
        \\  audit_db:
        \\    driver: sqlite
        \\    path: ":memory:"
        \\  search_sink:
        \\    driver: elasticsearch
        \\    endpoint: "http://localhost:9200"
        \\    index: "vidsec_findings"
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: stage0_probe
        \\        uses: analyzer/probe_file
        \\        in: stream
        \\        concurrency: 2
        \\        params:
        \\          min_size: "1024"
        \\        outputs:
        \\          coordination:
        \\            datasource: pipeline_memory
        \\      - router: check_risk
        \\        cases:
        \\          - when: "should_quarantine"
        \\            goto: quarantine
        \\        default: finalize
        \\  quarantine:
        \\    steps:
        \\      - id: isolate_file
        \\        uses: quarantine/move
        \\        in: stream
        \\  finalize:
        \\    steps:
        \\      - id: emit_audit
        \\        uses: audit/persist
        \\        in: stream
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pipeline_ast = try yaml_mod.loadPipelineAstFromYaml(alloc, yaml_text, .{});

    // 1. Runtime
    try std.testing.expectEqual(@as(usize, 4), pipeline_ast.runtime.workers);

    // 2. Datasources
    try std.testing.expectEqual(@as(usize, 3), pipeline_ast.datasources.len);
    const es_ds = pipeline_ast.getDatasource("search_sink");
    try std.testing.expect(es_ds != null);
    try std.testing.expectEqualStrings("elasticsearch", es_ds.?.driver);
    try std.testing.expectEqualStrings("http://localhost:9200", es_ds.?.getParam("endpoint").?);
    try std.testing.expectEqualStrings("vidsec_findings", es_ds.?.getParam("index").?);

    const mem_ds = pipeline_ast.getDatasource("pipeline_memory");
    try std.testing.expect(mem_ds != null);
    try std.testing.expectEqualStrings("memory", mem_ds.?.driver);

    // 3. Pipelines & Steps
    try std.testing.expectEqual(@as(usize, 3), pipeline_ast.pipelines.len);
    const main_pipe = pipeline_ast.getPipeline("main");
    try std.testing.expect(main_pipe != null);
    try std.testing.expectEqual(@as(usize, 2), main_pipe.?.steps.len);

    // Step 0: task
    const step0 = main_pipe.?.steps[0];
    try std.testing.expectEqualStrings("stage0_probe", step0.id());
    switch (step0) {
        .task => |t| {
            try std.testing.expectEqualStrings("analyzer", t.module);
            try std.testing.expectEqualStrings("probe_file", t.task);
            try std.testing.expectEqual(@as(?usize, 2), t.concurrency);
            try std.testing.expectEqual(@as(usize, 1), t.inputs.len);
            try std.testing.expectEqualStrings("stream", t.inputs[0].expr.stream_ref.?);
            try std.testing.expectEqual(@as(usize, 1), t.outputs.len);
            try std.testing.expectEqualStrings("pipeline_memory", t.outputs[0].datasource);
        },
        .router => return error.TestUnexpectedResult,
    }

    // Step 1: router
    const step1 = main_pipe.?.steps[1];
    try std.testing.expectEqualStrings("check_risk", step1.id());
    switch (step1) {
        .router => |r| {
            try std.testing.expectEqual(@as(usize, 1), r.cases.len);
            try std.testing.expectEqualStrings("should_quarantine", r.cases[0].when_predicate);
            try std.testing.expectEqualStrings("quarantine", r.cases[0].goto_pipeline);
            try std.testing.expectEqualStrings("finalize", r.default_pipeline.?);
        },
        .task => return error.TestUnexpectedResult,
    }
}

test "YAML to AST: Inbound stream algebra expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Direct
    const direct_expr = try yaml_mod.ast_loader.parseInboundStreamExpr(alloc, "stream_a");
    try std.testing.expectEqual(ast_mod.AlgebraOp.none, direct_expr.op);
    try std.testing.expectEqualStrings("stream_a", direct_expr.stream_ref.?);

    // Merge
    const merge_expr = try yaml_mod.ast_loader.parseInboundStreamExpr(alloc, "merge(s1, s2, s3)");
    try std.testing.expectEqual(ast_mod.AlgebraOp.merge, merge_expr.op);
    try std.testing.expectEqual(@as(usize, 3), merge_expr.sub_streams.len);
    try std.testing.expectEqualStrings("s1", merge_expr.sub_streams[0].stream_ref.?);
    try std.testing.expectEqualStrings("s2", merge_expr.sub_streams[1].stream_ref.?);
    try std.testing.expectEqualStrings("s3", merge_expr.sub_streams[2].stream_ref.?);

    // Zip
    const zip_expr = try yaml_mod.ast_loader.parseInboundStreamExpr(alloc, "zip(left_s, right_s)");
    try std.testing.expectEqual(ast_mod.AlgebraOp.zip, zip_expr.op);
    try std.testing.expectEqual(@as(usize, 2), zip_expr.sub_streams.len);
    try std.testing.expectEqualStrings("left_s", zip_expr.sub_streams[0].stream_ref.?);
    try std.testing.expectEqualStrings("right_s", zip_expr.sub_streams[1].stream_ref.?);

    // Join
    const join_expr = try yaml_mod.ast_loader.parseInboundStreamExpr(alloc, "join(atoms, findings, on: region_id)");
    try std.testing.expectEqual(ast_mod.AlgebraOp.join, join_expr.op);
    try std.testing.expectEqual(@as(usize, 2), join_expr.sub_streams.len);
    try std.testing.expectEqualStrings("atoms", join_expr.sub_streams[0].stream_ref.?);
    try std.testing.expectEqualStrings("findings", join_expr.sub_streams[1].stream_ref.?);
    try std.testing.expectEqualStrings("region_id", join_expr.join_key.?);
}

test "YAML to AST: Environment variable interpolation in YAML values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interp = yaml_mod.EnvInterpolator.init(false);
    defer interp.deinit(alloc);
    try interp.put(alloc, "MY_DB_PATH", "/var/vidsec/custom.db");
    try interp.put(alloc, "MY_WORKERS", "8");

    const yaml_text =
        \\version: 2
        \\runtime:
        \\  workers: "${MY_WORKERS:-1}"
        \\datasources:
        \\  audit_db:
        \\    driver: sqlite
        \\    path: "${MY_DB_PATH:-default.db}"
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_one
        \\        uses: core/noop
        \\        in: stream
    ;

    const pipeline_ast = try yaml_mod.loadPipelineAstFromYaml(alloc, yaml_text, .{
        .env_interpolator = &interp,
    });

    try std.testing.expectEqual(@as(usize, 8), pipeline_ast.runtime.workers);
    const db_ds = pipeline_ast.getDatasource("audit_db");
    try std.testing.expect(db_ds != null);
    try std.testing.expectEqualStrings("/var/vidsec/custom.db", db_ds.?.getParam("path").?);
}

test "YAML to AST: Semantic validation detects router cycle from YAML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_cycle =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - router: r_main
        \\        cases:
        \\          - when: "condition"
        \\            goto: sub_a
        \\  sub_a:
        \\    steps:
        \\      - router: r_a
        \\        cases:
        \\          - when: "condition"
        \\            goto: sub_b
        \\  sub_b:
        \\    steps:
        \\      - router: r_b
        \\        cases:
        \\          - when: "condition"
        \\            goto: sub_a
    ;

    const res = yaml_mod.loadPipelineAstFromYaml(alloc, yaml_cycle, .{});
    try std.testing.expectError(error.CircularRouterReference, res);
}

test "YAML to AST: Parse actual configs/pipeline.yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file_content = try vidsec.pipeline.readFileBytes(alloc, "apps/vidsec/configs/pipeline.yaml");

    var interp = yaml_mod.EnvInterpolator.init(false);
    defer interp.deinit(alloc);

    const ast = try yaml_mod.loadPipelineAstFromYaml(alloc, file_content, .{
        .env_interpolator = &interp,
    });

    try std.testing.expect(ast.datasources.len >= 3);
    try std.testing.expect(ast.getPipeline("main") != null);
    try std.testing.expect(ast.getPipeline("mp4_pipeline") != null);
    try std.testing.expect(ast.getPipeline("quarantine_flow") != null);
}

test "Schema Loader: run all tests in schema_loader" {
    std.testing.refAllDecls(yaml_mod.schema_loader);
}

test "YAML to AST: Parse runtime.routing and per-pipeline routing overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_text =
        \\version: 2
        \\runtime:
        \\  workers: 2
        \\  scheduler: dag
        \\  routing: type_driven
        \\pipelines:
        \\  mesh_pipe:
        \\    steps:
        \\      - id: s1
        \\        uses: mod/task_a
        \\  etl_pipe:
        \\    routing: directed
        \\    steps:
        \\      - id: s2
        \\        uses: mod/task_b
        \\  hybrid_pipe:
        \\    routing: hybrid
        \\    steps:
        \\      - id: s3
        \\        uses: mod/task_c
    ;

    const ast = try yaml_mod.loadPipelineAstFromYaml(alloc, yaml_text, .{});
    try std.testing.expectEqual(yaml_mod.RoutingMode.type_driven, ast.runtime.routing);

    const mesh = ast.getPipeline("mesh_pipe").?;
    try std.testing.expectEqual(@as(?yaml_mod.RoutingMode, null), mesh.routing);
    try std.testing.expectEqual(yaml_mod.RoutingMode.type_driven, mesh.effectiveRouting(ast.runtime.routing));

    const etl = ast.getPipeline("etl_pipe").?;
    try std.testing.expectEqual(@as(?yaml_mod.RoutingMode, .directed), etl.routing);
    try std.testing.expectEqual(yaml_mod.RoutingMode.directed, etl.effectiveRouting(ast.runtime.routing));

    const hybrid = ast.getPipeline("hybrid_pipe").?;
    try std.testing.expectEqual(yaml_mod.RoutingMode.hybrid, hybrid.effectiveRouting(ast.runtime.routing));
}

test "YAML to AST: Rejects invalid routing mode in runtime or pipeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bad_runtime_yaml =
        \\version: 2
        \\runtime:
        \\  routing: magic_mode
        \\pipelines:
        \\  main:
        \\    steps: []
    ;
    try std.testing.expectError(error.InvalidRoutingMode, yaml_mod.loadPipelineAstFromYaml(alloc, bad_runtime_yaml, .{}));

    const bad_pipe_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    routing: reactive
        \\    steps: []
    ;
    try std.testing.expectError(error.InvalidRoutingMode, yaml_mod.loadPipelineAstFromYaml(alloc, bad_pipe_yaml, .{}));
}
