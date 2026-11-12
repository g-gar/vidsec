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
    try std.testing.expectEqual(@as(usize, 4), ast.runtime.workers);
    try std.testing.expectEqual(flowdata.ast.SchedulerMode.dag, ast.runtime.scheduler);

    // 2. Validate declared datasources
    try std.testing.expect(ast.getDatasource("tracked_targets") != null);
    try std.testing.expectEqualStrings("yaml_file", ast.getDatasource("tracked_targets").?.driver);

    try std.testing.expect(ast.getDatasource("pipeline_memory") != null);
    try std.testing.expectEqualStrings("memory", ast.getDatasource("pipeline_memory").?.driver);

    try std.testing.expect(ast.getDatasource("catalog_db") != null);
    try std.testing.expectEqualStrings("sqlite", ast.getDatasource("catalog_db").?.driver);

    // 3. Validate declared modules
    try std.testing.expectEqual(@as(usize, 1), ast.modules.len);
    try std.testing.expectEqualStrings("manga_catalog", ast.modules[0].name);
    try std.testing.expectEqualStrings("./zig-out/lib/libmanga_catalog.so", ast.modules[0].path);

    // 4. Validate main pipeline and all 8 steps
    const main_pipe = ast.getPipeline("main");
    try std.testing.expect(main_pipe != null);
    try std.testing.expectEqual(@as(usize, 8), main_pipe.?.steps.len);

    // Step 1: fetch_details
    const step1 = main_pipe.?.steps[0].task;
    try std.testing.expectEqualStrings("fetch_details", step1.id);
    try std.testing.expectEqualStrings("manga_catalog", step1.module);
    try std.testing.expectEqualStrings("fetch_series_details", step1.task);
    try std.testing.expect(step1.inputs.len >= 1);
    try std.testing.expectEqualStrings("tracked_targets", step1.inputs[0].expr.stream_ref.?);
    try std.testing.expect(step1.outputs.len >= 2);
    try std.testing.expectEqualStrings("series_details", step1.outputs[0].name);
    try std.testing.expectEqualStrings("pipeline_memory", step1.outputs[0].datasource);
    try std.testing.expectEqualStrings("catalog_series", step1.outputs[1].name);
    try std.testing.expectEqualStrings("catalog_db", step1.outputs[1].datasource);

    // Step 2: fetch_chapters
    const step2 = main_pipe.?.steps[1].task;
    try std.testing.expectEqualStrings("fetch_chapters", step2.id);
    try std.testing.expectEqualStrings("manga_catalog", step2.module);
    try std.testing.expectEqualStrings("fetch_chapters", step2.task);
    try std.testing.expect(step2.inputs.len >= 1);
    try std.testing.expectEqualStrings("series_details", step2.inputs[0].expr.stream_ref.?);
    try std.testing.expect(step2.outputs.len >= 1);
    try std.testing.expectEqualStrings("discovered_chapters", step2.outputs[0].name);
    try std.testing.expectEqualStrings("catalog_db", step2.outputs[0].datasource);

    // Step 3: fetch_pages
    const step3 = main_pipe.?.steps[2].task;
    try std.testing.expectEqualStrings("fetch_pages", step3.id);
    try std.testing.expectEqualStrings("manga_catalog", step3.module);
    try std.testing.expectEqualStrings("fetch_chapter_pages", step3.task);
    try std.testing.expectEqual(@as(?usize, 4), step3.concurrency);
    try std.testing.expect(step3.inputs.len >= 1);
    try std.testing.expectEqualStrings("discovered_chapters", step3.inputs[0].expr.stream_ref.?);
    try std.testing.expect(step3.outputs.len >= 1);
    try std.testing.expectEqualStrings("discovered_pages", step3.outputs[0].name);
    try std.testing.expectEqualStrings("catalog_db", step3.outputs[0].datasource);

    // Step 4: download_pages
    const step4 = main_pipe.?.steps[3].task;
    try std.testing.expectEqualStrings("download_pages", step4.id);
    try std.testing.expectEqualStrings("manga_catalog", step4.module);
    try std.testing.expectEqualStrings("download_chapter_page", step4.task);
    try std.testing.expectEqual(@as(?usize, 4), step4.concurrency);
    try std.testing.expect(step4.inputs.len >= 1);
    try std.testing.expectEqualStrings("fetch_pages.discovered_pages", step4.inputs[0].expr.stream_ref.?);
    try std.testing.expect(step4.outputs.len >= 1);
    try std.testing.expectEqualStrings("downloaded_pages", step4.outputs[0].name);
    try std.testing.expectEqualStrings("pipeline_memory", step4.outputs[0].datasource);

    // Step 5: detect_formats
    const step5 = main_pipe.?.steps[4].task;
    try std.testing.expectEqualStrings("detect_formats", step5.id);
    try std.testing.expectEqualStrings("manga_catalog", step5.module);
    try std.testing.expectEqualStrings("detect_content_type", step5.task);
    try std.testing.expectEqual(@as(?usize, 4), step5.concurrency);
    try std.testing.expect(step5.inputs.len >= 1);
    try std.testing.expectEqualStrings("download_pages.downloaded_pages", step5.inputs[0].expr.stream_ref.?);
    try std.testing.expect(step5.outputs.len >= 1);
    try std.testing.expectEqualStrings("pages_with_types", step5.outputs[0].name);
    try std.testing.expectEqualStrings("pipeline_memory", step5.outputs[0].datasource);

    // Step 6: analyze_pages
    const step6 = main_pipe.?.steps[5].task;
    try std.testing.expectEqualStrings("analyze_pages", step6.id);
    try std.testing.expectEqualStrings("manga_catalog", step6.module);
    try std.testing.expectEqualStrings("analyze_image", step6.task);
    try std.testing.expectEqual(@as(?usize, 4), step6.concurrency);
    try std.testing.expect(step6.inputs.len >= 1);
    try std.testing.expectEqualStrings("detect_formats.pages_with_types", step6.inputs[0].expr.stream_ref.?);
    try std.testing.expect(step6.static_params.len >= 3);
    try std.testing.expect(step6.outputs.len >= 1);
    try std.testing.expectEqualStrings("analyzed_pages", step6.outputs[0].name);
    try std.testing.expectEqualStrings("pipeline_memory", step6.outputs[0].datasource);

    // Step 7: generate_comicinfo
    const step7 = main_pipe.?.steps[6].task;
    try std.testing.expectEqualStrings("generate_comicinfo", step7.id);
    try std.testing.expectEqualStrings("manga_catalog", step7.module);
    try std.testing.expectEqualStrings("generate_comicinfo", step7.task);
    try std.testing.expect(step7.inputs.len >= 1);
    try std.testing.expectEqualStrings("series_details", step7.inputs[0].expr.stream_ref.?);
    try std.testing.expect(step7.outputs.len >= 1);
    try std.testing.expectEqualStrings("comic_info_xml", step7.outputs[0].name);
    try std.testing.expectEqualStrings("pipeline_memory", step7.outputs[0].datasource);

    // Step 8: build_cbz
    const step8 = main_pipe.?.steps[7].task;
    try std.testing.expectEqualStrings("build_cbz", step8.id);
    try std.testing.expectEqualStrings("manga_catalog", step8.module);
    try std.testing.expectEqualStrings("build_cbz_archive", step8.task);
    try std.testing.expect(step8.inputs.len >= 1);
    try std.testing.expectEqualStrings("detect_formats.pages_with_types", step8.inputs[0].expr.stream_ref.?);
    try std.testing.expect(step8.after.len >= 1);
    try std.testing.expectEqualStrings("generate_comicinfo", step8.after[0]);
    try std.testing.expect(step8.outputs.len >= 1);
    try std.testing.expectEqualStrings("cbz_archive", step8.outputs[0].name);
    try std.testing.expectEqualStrings("pipeline_memory", step8.outputs[0].datasource);
}
