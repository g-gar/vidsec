const std = @import("std");
const flowdata = @import("flowdata");
const sqlite_driver = @import("flowdata_datasource_sqlite");
const SeriesDetails = @import("mangadex_plugin").tasks.fetch_series_details.SeriesDetails;
const RepositoryRegistry = flowdata.RepositoryRegistry;
const WriteSpec = flowdata.dataflow.WriteSpec;
const ReadSpec = flowdata.dataflow.ReadSpec;
const PayloadHandle = flowdata.dataflow.PayloadHandle;
const PredicateNode = flowdata.dataflow.predicate_ast.PredicateNode;

test "MangaDex catalog_db works end-to-end with SQLite driver and schemas.yaml" {
    const alloc = std.testing.allocator;

    var registry = RepositoryRegistry.init(alloc);
    defer registry.deinit();
    try registry.registerDriver("sqlite", &sqlite_driver.SqliteRepository.createHeap);

    const params = [_]flowdata.repository.ConfigParam{
        .{ .key = "path", .value = ":memory:" },
        .{ .key = "schema", .value = "configs/schemas.yaml" },
    };

    const repo = try registry.resolveOrCreate(.{
        .id = "catalog_db",
        .driver = "sqlite",
        .params = &params,
    });

    // 1. Write SeriesDetails into catalog_series (tests upsert + schema field projection)
    const series = SeriesDetails{
        .series_id = "9d45ff11-2385-4179-8663-e0dbb0ebd792",
        .source_id = "mangadex",
        .title = "Low Orbit Human",
        .author = "Test Author",
        .status = "ongoing",
        .year = 2024,
        .available_languages = "en,es",
        .target_chapters = "all",
        .library = "Manga",
    };

    try repo.write(.{
        .table = "catalog_series",
        .mode = .upsert,
        .payload = PayloadHandle.fromScalar(SeriesDetails, &series),
    });

    // 2. Query catalog_series back using PredicateNode
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const pred = PredicateNode{
        .cmp = .{
            .column = "series_id",
            .op = .eq,
            .value = .{ .text = "9d45ff11-2385-4179-8663-e0dbb0ebd792" },
        },
    };
    const result = try repo.read(aa, .{
        .table = "catalog_series",
        .projection = .{ .include = &.{ "series_id", "title", "status", "year" } },
        .where = &pred,
    });

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const rows = result.asSlice(flowdata.dataflow.DynamicRecord);
    try std.testing.expectEqualStrings("Low Orbit Human", rows[0].getReflected("title").?.string);
    try std.testing.expectEqual(@as(i64, 2024), rows[0].getReflected("year").?.int);

    // 3. Verify discovered_chapters FK + CASCADE delete
    const ChapterRow = struct {
        source_chapter_id: []const u8,
        series_id: []const u8,
        chapter_number: []const u8,
        language: []const u8,
        page_count: i64,
        status: []const u8,
    };
    const ch = ChapterRow{
        .source_chapter_id = "ch-001",
        .series_id = "9d45ff11-2385-4179-8663-e0dbb0ebd792",
        .chapter_number = "1",
        .language = "en",
        .page_count = 12,
        .status = "discovered",
    };
    try repo.write(.{
        .table = "discovered_chapters",
        .mode = .upsert,
        .payload = PayloadHandle.fromScalar(ChapterRow, &ch),
    });

    // Delete parent series -> child chapter must cascade delete
    try repo.write(.{
        .table = "catalog_series",
        .mode = .delete,
        .payload = PayloadHandle.fromScalar(SeriesDetails, &series),
    });

    const ch_after = try repo.read(aa, .{
        .table = "discovered_chapters",
        .projection = .{ .include = &.{"source_chapter_id"} },
    });
    try std.testing.expectEqual(@as(usize, 0), ch_after.len);
}
