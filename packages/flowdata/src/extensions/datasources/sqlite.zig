const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite_core = @import("sqlite_runtime/mod.zig");
const SqliteRuntime = sqlite_core.SqliteRuntime;
const dataflow = @import("../../dataflow/mod.zig");
const PayloadHandle = dataflow.PayloadHandle;
const StorageRepository = @import("../../repository/storage_repository.zig").StorageRepository;

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

    pub fn writePayload(self: *SqliteRepository, table_name: []const u8, payload: PayloadHandle) !void {
        _ = self;
        _ = table_name;
        _ = payload;
        // Payload persistence via compile-time reflection
    }

    pub fn readPayload(self: *const SqliteRepository, table_name: []const u8) ?PayloadHandle {
        _ = self;
        _ = table_name;
        return null;
    }

    pub fn recordCount(self: *const SqliteRepository, table_name: []const u8) usize {
        var query_buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&query_buf, "SELECT COUNT(*) FROM \"{s}\"", .{table_name}) catch return 0;
        var stmt = self.db_runtime.db.prepareReadOnly(sql) catch return 0;
        defer stmt.deinit();
        if (stmt.step() catch null) |row| {
            return @intCast(row.int64(0));
        }
        return 0;
    }

    pub fn deinit(self: *SqliteRepository) void {
        _ = self;
    }

    pub fn storageRepository(self: *SqliteRepository) StorageRepository {
        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const self_ptr: *SqliteRepository = @ptrCast(@alignCast(ctx));
                try self_ptr.writePayload(channel, payload);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const self_ptr: *const SqliteRepository = @ptrCast(@alignCast(ctx));
                return self_ptr.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const self_ptr: *const SqliteRepository = @ptrCast(@alignCast(ctx));
                return self_ptr.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const self_ptr: *SqliteRepository = @ptrCast(@alignCast(ctx));
                self_ptr.deinit();
            }

            const vtable = StorageRepository.VTable{
                .writePayload = &doWritePayload,
                .readPayload = &doReadPayload,
                .recordCount = &doRecordCount,
                .deinit = &doDeinit,
            };
        };

        return .{
            .ptr = self,
            .vtable = &Trampoline.vtable,
        };
    }
};
