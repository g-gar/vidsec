const std = @import("std");
const flowdata = @import("flowdata");
const yaml_core = flowdata.yaml;

test "MangaDex pipeline.yaml parses and validates into PipelineAST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const yaml_bytes = try flowdata.readFileBytes(alloc, "configs/pipeline.yaml");

    var env_interp = yaml_core.EnvInterpolator.init(false);
    const ast = try yaml_core.loadPipelineAstFromYaml(alloc, yaml_bytes, .{
        .env_interpolator = &env_interp,
    });

    // 1. Validate runtime
    try std.testing.expectEqual(@as(usize, 1), ast.runtime.workers);

    // 2. Validate declared datasources
    try std.testing.expect(ast.getDatasource("pipeline_memory") != null);
    try std.testing.expectEqualStrings("memory", ast.getDatasource("pipeline_memory").?.driver);

    try std.testing.expect(ast.getDatasource("catalog_db") != null);
    try std.testing.expectEqualStrings("sqlite", ast.getDatasource("catalog_db").?.driver);

    // 3. Validate declared modules
    try std.testing.expectEqual(@as(usize, 1), ast.modules.len);
    try std.testing.expectEqualStrings("manga_catalog", ast.modules[0].name);
    try std.testing.expectEqualStrings("./zig-out/lib/libmanga_catalog.so", ast.modules[0].path);

    // 4. Validate main pipeline and steps
    const main_pipe = ast.getPipeline("main");
    try std.testing.expect(main_pipe != null);
    try std.testing.expectEqual(@as(usize, 2), main_pipe.?.steps.len);

    // Step 1: fetch_details
    const step1 = main_pipe.?.steps[0].task;
    try std.testing.expectEqualStrings("fetch_details", step1.id);
    try std.testing.expectEqualStrings("manga_catalog", step1.module);
    try std.testing.expectEqualStrings("fetch_series_details", step1.task);
    try std.testing.expect(step1.outputs.len >= 1);
    try std.testing.expectEqualStrings("series_details", step1.outputs[0].name);
    try std.testing.expectEqualStrings("pipeline_memory", step1.outputs[0].datasource);

    // Step 2: fetch_chapters
    const step2 = main_pipe.?.steps[1].task;
    try std.testing.expectEqualStrings("fetch_chapters", step2.id);
    try std.testing.expectEqualStrings("manga_catalog", step2.module);
    try std.testing.expectEqualStrings("fetch_chapters", step2.task);
    try std.testing.expect(step2.inputs.len >= 1);
    try std.testing.expectEqualStrings("series_details", step2.inputs[0].expr.stream_ref.?);
    try std.testing.expect(step2.outputs.len >= 1);
    try std.testing.expectEqualStrings("discovered_chapters", step2.outputs[0].name);
    try std.testing.expectEqualStrings("pipeline_memory", step2.outputs[0].datasource);
}
