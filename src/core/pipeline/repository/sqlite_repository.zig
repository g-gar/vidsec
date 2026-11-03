const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite_core = @import("../../sqlite/mod.zig");
const SqliteRuntime = sqlite_core.SqliteRuntime;
const NamedValue = sqlite_core.NamedValue;
const StorageRepository = @import("storage_repository.zig").StorageRepository;

/// Storage repository backed by SQLite.
pub const SqliteRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    allocator: Allocator,
    db_runtime: *SqliteRuntime,

    pub fn init(allocator: Allocator, db_runtime: *SqliteRuntime) SqliteRepository {
        return .{
            .allocator = allocator,
            .db_runtime = db_runtime,
        };
    }

    pub fn storageRepository(self: *SqliteRepository) StorageRepository {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn saveRecord(self: *SqliteRepository, table_name: []const u8, fields: []const NamedValue) !void {
        var sink = try self.db_runtime.prepareSink(self.allocator, table_name, null);
        defer sink.deinit();
        try sink.emitRow(fields);
    }

    pub fn recordCount(self: *SqliteRepository, table_name: []const u8) usize {
        var query_buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&query_buf, "SELECT COUNT(*) FROM \"{s}\"", .{table_name}) catch return 0;
        var stmt = self.db_runtime.db.prepareReadOnly(sql) catch return 0;
        defer stmt.deinit();
        if (stmt.step() catch null) |row| {
            return @intCast(row.int64(0));
        }
        return 0;
    }

    const vtable = StorageRepository.VTable{
        .saveRecord = saveRecordImpl,
        .recordCount = recordCountImpl,
        .deinit = deinitImpl,
    };

    fn saveRecordImpl(ctx: *anyopaque, table_name: []const u8, fields: []const NamedValue) anyerror!void {
        const self: *SqliteRepository = @ptrCast(@alignCast(ctx));
        try self.saveRecord(table_name, fields);
    }

    fn recordCountImpl(ctx: *anyopaque, table_name: []const u8) usize {
        const self: *SqliteRepository = @ptrCast(@alignCast(ctx));
        return self.recordCount(table_name);
    }

    fn deinitImpl(_: *anyopaque) void {}
};
