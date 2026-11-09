pub const lib = @import("sqlite_lib/mod.zig");
pub const repository = @import("sqlite_repository.zig");

pub const SqliteRepository = repository.SqliteRepository;
pub const Db = lib.Db;

const std = @import("std");
const flowdata = @import("flowdata");

test "SqliteRepository writes DynamicRecords and persists tables" {
    const alloc = std.testing.allocator;
    const db = try Db.openMemory(.{});
    var repo = SqliteRepository.init(alloc, db);
    defer repo.deinit();

    const fields = try alloc.alloc(flowdata.dataflow.DynamicField, 3);
    defer alloc.free(fields);
    fields[0] = .{ .name = "series_id", .value = .{ .string = "manga-123" } };
    fields[1] = .{ .name = "title", .value = .{ .string = "Frieren" } };
    fields[2] = .{ .name = "year", .value = .{ .int = 2020 } };

    const records = try alloc.alloc(flowdata.dataflow.DynamicRecord, 1);
    defer alloc.free(records);
    records[0] = flowdata.dataflow.DynamicRecord.init(fields);

    const payload = flowdata.dataflow.PayloadHandle.fromSlice(flowdata.dataflow.DynamicRecord, records);
    try repo.writePayload("catalog_series", payload);

    try std.testing.expectEqual(@as(usize, 1), repo.recordCount("catalog_series"));

    var stmt = try repo.db.prepare("SELECT series_id, title, year FROM \"catalog_series\"");
    defer stmt.deinit();

    const row = (try stmt.step()).?;
    try std.testing.expectEqualStrings("manga-123", row.text(0));
    try std.testing.expectEqualStrings("Frieren", row.text(1));
    try std.testing.expectEqual(@as(i64, 2020), row.int64(2));
}
