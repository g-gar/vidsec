const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const PayloadHandle = flowdata.dataflow.PayloadHandle;
const repository = flowdata.repository;
const StorageRepository = repository.StorageRepository;
const sqlite_lib = @import("sqlite_lib/mod.zig");
const schema_provisioner = @import("schema_provisioner.zig");
const Db = sqlite_lib.Db;
const Value = sqlite_lib.Value;

fn reflectedToSqlite(val: flowdata.dataflow.ReflectedValue) Value {
    return switch (val) {
        .none, .unsupported => .null_val,
        .int => |v| .{ .int64 = v },
        .uint => |v| .{ .int64 = @intCast(v) },
        .float => |v| .{ .float64 = v },
        .boolean => |v| .{ .boolean = v },
        .string => |v| .{ .text = v },
        .bytes => |v| .{ .blob = v },
    };
}

fn reflectedSqlType(val: flowdata.dataflow.ReflectedValue) []const u8 {
    return switch (val) {
        .int, .uint, .boolean => "INTEGER",
        .float => "REAL",
        .bytes => "BLOB",
        else => "TEXT",
    };
}

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
        if (payload.len == 0) return;

        if (std.mem.endsWith(u8, payload.type_name, "DynamicRecord")) {
            const records = payload.asSlice(flowdata.dataflow.DynamicRecord);
            if (records.len == 0) return;

            const first = records[0];
            if (first.fields.len == 0) return;

            // 1. Build and run CREATE TABLE IF NOT EXISTS
            var ddl_buf = std.ArrayListUnmanaged(u8).empty;
            defer ddl_buf.deinit(self.allocator);

            try ddl_buf.appendSlice(self.allocator, "CREATE TABLE IF NOT EXISTS \"");
            try ddl_buf.appendSlice(self.allocator, table_name);
            try ddl_buf.appendSlice(self.allocator, "\" (");
            for (first.fields, 0..) |f, i| {
                if (i > 0) try ddl_buf.appendSlice(self.allocator, ", ");
                try ddl_buf.appendSlice(self.allocator, "\"");
                try ddl_buf.appendSlice(self.allocator, f.name);
                try ddl_buf.appendSlice(self.allocator, "\" ");
                try ddl_buf.appendSlice(self.allocator, reflectedSqlType(f.value));
            }
            try ddl_buf.appendSlice(self.allocator, ");");
            self.db.exec(ddl_buf.items) catch |err| {
                std.log.err("[SQLite writePayload] DDL exec failed: {s} | DDL: {s}", .{
                    self.db.lastErrorMessage(),
                    ddl_buf.items,
                });
                return err;
            };

            // Dynamically ensure columns exist if the table was pre-created with fewer columns
            for (first.fields) |f| {
                var alter_buf: [256]u8 = undefined;
                const alter_sql = std.fmt.bufPrint(
                    &alter_buf,
                    "ALTER TABLE \"{s}\" ADD COLUMN \"{s}\" {s};",
                    .{ table_name, f.name, reflectedSqlType(f.value) },
                ) catch continue;
                self.db.exec(alter_sql) catch {};
            }

            // 2. Prepare INSERT statement
            var ins_buf = std.ArrayListUnmanaged(u8).empty;
            defer ins_buf.deinit(self.allocator);

            try ins_buf.appendSlice(self.allocator, "INSERT OR REPLACE INTO \"");
            try ins_buf.appendSlice(self.allocator, table_name);
            try ins_buf.appendSlice(self.allocator, "\" (");
            for (first.fields, 0..) |f, i| {
                if (i > 0) try ins_buf.appendSlice(self.allocator, ", ");
                try ins_buf.appendSlice(self.allocator, "\"");
                try ins_buf.appendSlice(self.allocator, f.name);
                try ins_buf.appendSlice(self.allocator, "\"");
            }
            try ins_buf.appendSlice(self.allocator, ") VALUES (");
            for (first.fields, 0..) |_, i| {
                if (i > 0) try ins_buf.appendSlice(self.allocator, ", ?");
                if (i == 0) try ins_buf.appendSlice(self.allocator, "?");
            }
            try ins_buf.appendSlice(self.allocator, ");");

            var stmt = self.db.prepare(ins_buf.items) catch |err| {
                std.log.err("[SQLite writePayload] prepare failed for table '{s}': {s} | SQL: {s}", .{
                    table_name,
                    self.db.lastErrorMessage(),
                    ins_buf.items,
                });
                return err;
            };
            defer stmt.deinit();

            for (records) |rec| {
                stmt.resetAndClear();
                for (rec.fields, 1..) |f, col_idx| {
                    try stmt.bindValue(col_idx, reflectedToSqlite(f.value));
                }
                stmt.execStep() catch |err| {
                    std.log.err("[SQLite writePayload] execStep failed for table '{s}': {s}", .{
                        table_name,
                        self.db.lastErrorMessage(),
                    });
                    return err;
                };
            }
        }
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
        var schema_path: ?[]const u8 = null;
        for (params) |p| {
            if (std.mem.eql(u8, p.key, "path")) {
                db_path = p.value;
            } else if (std.mem.eql(u8, p.key, "schema") or std.mem.eql(u8, p.key, "schemas") or std.mem.eql(u8, p.key, "schemas_path")) {
                schema_path = p.value;
            }
        }

        if (schema_path == null) {
            if (std.c.fopen("configs/schemas.yaml", "rb")) |fp| {
                _ = std.c.fclose(fp);
                schema_path = "configs/schemas.yaml";
            }
        }

        const is_mem = std.mem.eql(u8, db_path, ":memory:");
        var opened_db = if (is_mem)
            try Db.openMemory(.{
                .busy_timeout_ms = 5000,
                .foreign_keys = true,
            })
        else
            try Db.openFile(allocator, db_path, .{
                .busy_timeout_ms = 5000,
                .foreign_keys = true,
                .journal_mode = .wal,
                .synchronous = .normal,
            });

        if (!is_mem) {
            opened_db.exec("PRAGMA auto_vacuum = INCREMENTAL;") catch {};
        }

        if (schema_path) |spath| {
            if (flowdata.readFileBytes(allocator, spath)) |bytes| {
                defer allocator.free(bytes);
                var schema_arena = std.heap.ArenaAllocator.init(allocator);
                defer schema_arena.deinit();
                const arena = schema_arena.allocator();

                var catalog = flowdata.yaml.SchemaCatalog.parseYaml(arena, bytes, null) catch null;
                if (catalog) |*cat| {
                    cat.yamlValidate(arena) catch {};
                    schema_provisioner.provisionCatalog(allocator, &opened_db, cat) catch {};
                }
            } else |_| {}
        }

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
