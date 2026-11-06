const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const PayloadHandle = flowdata.dataflow.PayloadHandle;
const repository = flowdata.repository;
const StorageRepository = repository.StorageRepository;
const sqlite_lib = @import("sqlite_lib/mod.zig");
const Db = sqlite_lib.Db;

/// Storage repository backed by SQLite.
pub const SqliteRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    allocator: Allocator,
    db: Db,

    pub fn init(allocator: Allocator, db: Db) SqliteRepository {
        return .{
            .allocator = allocator,
            .db = db,
        };
    }

    pub fn deinit(self: *SqliteRepository) void {
        self.db.close();
    }

    pub fn writePayload(self: *SqliteRepository, table_name: []const u8, payload: PayloadHandle) !void {
        _ = self;
        _ = table_name;
        _ = payload;
        // In-memory reflection persistence handled by pipeline runner/tracer
    }

    pub fn readPayload(self: *const SqliteRepository, table_name: []const u8) ?PayloadHandle {
        _ = self;
        _ = table_name;
        return null;
    }

    pub fn recordCount(self: *const SqliteRepository, table_name: []const u8) usize {
        var query_buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&query_buf, "SELECT COUNT(*) FROM \"{s}\"", .{table_name}) catch return 0;
        var db_mut = @constCast(&self.db);
        var stmt = db_mut.prepareReadOnly(sql) catch return 0;
        defer stmt.deinit();
        if (stmt.step() catch null) |row| {
            return @intCast(row.int64(0));
        }
        return 0;
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

    pub fn createHeap(allocator: Allocator, params: []const repository.ConfigParam) anyerror!StorageRepository {
        var db_path: []const u8 = ":memory:";
        for (params) |p| {
            if (std.mem.eql(u8, p.key, "path")) {
                db_path = p.value;
            }
        }

        const opened_db = if (std.mem.eql(u8, db_path, ":memory:"))
            try Db.openMemory(.{})
        else
            try Db.openFile(allocator, db_path, .{});

        const self_ptr = try allocator.create(SqliteRepository);
        self_ptr.* = .{
            .allocator = allocator,
            .db = opened_db,
        };

        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                try s.writePayload(channel, payload);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const s: *const SqliteRepository = @ptrCast(@alignCast(ctx));
                return s.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const s: *const SqliteRepository = @ptrCast(@alignCast(ctx));
                return s.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                const alloc = s.allocator;
                s.deinit();
                alloc.destroy(s);
            }

            const vtable = StorageRepository.VTable{
                .writePayload = &doWritePayload,
                .readPayload = &doReadPayload,
                .recordCount = &doRecordCount,
                .deinit = &doDeinit,
            };
        };

        return .{
            .ptr = self_ptr,
            .vtable = &Trampoline.vtable,
        };
    }
};
