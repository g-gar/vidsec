const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const schema = flowdata.schema;
const SchemaCatalog = schema.SchemaCatalog;
const TableSchema = schema.TableSchema;
const dataflow = flowdata.dataflow;
const PayloadHandle = dataflow.PayloadHandle;
const DynamicRecord = dataflow.DynamicRecord;
const ReflectedValue = dataflow.ReflectedValue;
const ReflectedField = dataflow.DynamicField;
const predicate_ast = dataflow.predicate_ast;
const PredicateNode = predicate_ast.PredicateNode;
const repository = flowdata.repository;
const Repository = repository.Repository;
const StorageRepository = repository.StorageRepository;
const ConfigParam = repository.ConfigParam;
const Capabilities = repository.Capabilities;
const WriteSpec = repository.WriteSpec;
const ReadSpec = repository.ReadSpec;
const RowIterator = repository.RowIterator;
const sql = @import("flowdata_sql");
const sqlite_lib = @import("flowdata_sqlite");
const Db = sqlite_lib.Db;
const Stmt = sqlite_lib.Stmt;
const StmtCache = sqlite_lib.StmtCache;
const Row = sqlite_lib.Row;
const OpenOptions = sqlite_lib.OpenOptions;
const schema_provisioner = @import("schema_provisioner.zig");
const MigrateMode = schema_provisioner.MigrateMode;
const predicate_compiler = @import("predicate_compiler.zig");

pub const SqliteRepoError = error{
    UnknownTable,
    DuplicatePrimaryKey,
    RowNotFound,
    MissingPrimaryKey,
};

fn reflectedToSqlValue(val: ReflectedValue) sql.SqlValue {
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

fn reflectedSqlType(val: ReflectedValue) []const u8 {
    return switch (val) {
        .int, .uint, .boolean => "INTEGER",
        .float => "REAL",
        .bytes => "BLOB",
        else => "TEXT",
    };
}

fn sqliteValueToReflected(allocator: Allocator, row: Row, col_idx: usize) !ReflectedValue {
    const col_type = sqlite_lib.c.sqlite3_column_type(row.stmt, @intCast(col_idx));
    return switch (col_type) {
        sqlite_lib.c.SQLITE_NULL => .none,
        sqlite_lib.c.SQLITE_INTEGER => .{ .int = row.int64(col_idx) },
        sqlite_lib.c.SQLITE_FLOAT => .{ .float = row.float64(col_idx) },
        sqlite_lib.c.SQLITE_TEXT => .{ .string = try allocator.dupe(u8, row.text(col_idx)) },
        sqlite_lib.c.SQLITE_BLOB => .{ .bytes = try allocator.dupe(u8, row.blob(col_idx)) },
        else => .none,
    };
}

fn appendQuotedIdent(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, ident: []const u8) !void {
    try buf.append(allocator, '"');
    for (ident) |ch| {
        if (ch == '"') {
            try buf.appendSlice(allocator, "\"\"");
        } else {
            try buf.append(allocator, ch);
        }
    }
    try buf.append(allocator, '"');
}

/// Storage repository backed by SQLite (ARCH-009B / ARCH-009D).
/// Synchronous, single-connection driver; DML & SELECT queries are built via
/// portable `libs/sql/` ASTs and executed through `libs/sqlite/` `StmtCache`.
pub const SqliteRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    allocator: Allocator,
    db: Db,
    stmt_cache: StmtCache,
    schemaless: bool = true,
    migrate_mode: MigrateMode = .auto,
    in_tx: bool = false,
    schema_arena: std.heap.ArenaAllocator,
    tables: std.StringHashMapUnmanaged(TableSchema) = .empty,

    pub fn init(allocator: Allocator, db: Db) SqliteRepository {
        return .{
            .allocator = allocator,
            .db = db,
            .stmt_cache = StmtCache.init(allocator, undefined),
            .schema_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn initWithConfig(allocator: Allocator, db: Db, schemaless: bool, migrate_mode: MigrateMode) SqliteRepository {
        var repo = SqliteRepository.init(allocator, db);
        repo.schemaless = schemaless;
        repo.migrate_mode = migrate_mode;
        return repo;
    }

    pub fn deinit(self: *SqliteRepository) void {
        self.stmt_cache.deinit();
        self.tables.deinit(self.allocator);
        self.schema_arena.deinit();
        self.db.close();
    }

    fn ensureStmtCacheDb(self: *SqliteRepository) void {
        self.stmt_cache.db = &self.db;
    }

    pub fn getCapabilities(_: *const SqliteRepository) Capabilities {
        return .{
            .transactions = true,
            .savepoints = true,
            .partial_update = true,
            .filter_pushdown = true,
            .order_pushdown = true,
            .relational_constraints = true,
            .schema_ddl = true,
            .streaming = true,
        };
    }

    pub fn ensureSchema(self: *SqliteRepository, catalog: *const SchemaCatalog) !void {
        try schema_provisioner.provisionCatalogWithMode(self.allocator, &self.db, catalog, self.migrate_mode);
        const arena = self.schema_arena.allocator();
        for (catalog.schemas.entries) |dom_entry| {
            for (dom_entry.value.entries) |tbl_entry| {
                const name_copy = try arena.dupe(u8, tbl_entry.key);
                try self.tables.put(self.allocator, name_copy, tbl_entry.value);
            }
        }
    }

    fn getTablePrimaryKeys(self: *const SqliteRepository, allocator: Allocator, table_name: []const u8) ![]const []const u8 {
        if (self.tables.get(table_name)) |tbl| {
            if (tbl.primary_key.len > 0) return tbl.primary_key;
            var pks: std.ArrayListUnmanaged([]const u8) = .empty;
            for (tbl.columns.entries) |col_entry| {
                if (col_entry.value.pk) {
                    try pks.append(allocator, col_entry.key);
                }
            }
            return try pks.toOwnedSlice(allocator);
        }
        return &.{};
    }

    fn buildPkWhereExpr(allocator: Allocator, pks: []const []const u8, fields: []const ReflectedField) !*const sql.Expr {
        var root: ?*const sql.Expr = null;
        for (pks) |pk_col| {
            const pk_val = findFieldValue(fields, pk_col) orelse return error.MissingPrimaryKey;
            const cmp_node = try allocator.create(sql.Expr);
            cmp_node.* = .{ .cmp = .{
                .column = pk_col,
                .op = .eq,
                .value = reflectedToSqlValue(pk_val),
            } };
            if (root) |prev| {
                const and_node = try allocator.create(sql.Expr);
                and_node.* = .{ .@"and" = .{ .left = prev, .right = cmp_node } };
                root = and_node;
            } else {
                root = cmp_node;
            }
        }
        return root orelse error.MissingPrimaryKey;
    }

    pub fn write(self: *SqliteRepository, ws: WriteSpec) !void {
        if (!self.schemaless and !self.tables.contains(ws.table)) {
            return error.UnknownTable;
        }
        if (ws.payload.len == 0 and ws.mode != .replace_all) return;

        self.ensureStmtCacheDb();

        const started_tx = !self.in_tx;
        if (started_tx) {
            try self.db.beginImmediate();
        }
        errdefer if (started_tx) {
            self.db.rollback() catch {};
        };

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        if (ws.mode == .replace_all) {
            const del_compiled = try sql.compileDelete(sqlite_lib.sqlite_dialect, scratch, .{ .table = ws.table });
            var del_stmt = try sqlite_lib.prepareCompiled(&self.db, del_compiled);
            defer del_stmt.deinit();
            try del_stmt.execStep();
            if (ws.payload.len == 0) {
                if (started_tx) try self.db.commit();
                return;
            }
        }

        const pks = try self.getTablePrimaryKeys(scratch, ws.table);
        const row_count = if (ws.payload.is_stream and ws.payload.repr != .bytes) ws.payload.len else 1;
        const elem0 = ws.payload.elementAt(0) orelse {
            if (started_tx) try self.db.commit();
            return;
        };
        const first_fields = try self.extractFields(scratch, ws.table, elem0);
        if (first_fields.len == 0) {
            if (started_tx) try self.db.commit();
            return;
        }

        if (self.schemaless and !self.tables.contains(ws.table)) {
            try self.ensureSchemalessTable(ws.table, first_fields);
        }

        switch (ws.mode) {
            .append, .replace_all, .upsert => {
                const col_names = try scratch.alloc([]const u8, first_fields.len);
                var upd_cols_list: std.ArrayListUnmanaged([]const u8) = .empty;
                for (first_fields, 0..) |f, i| {
                    col_names[i] = f.name;
                    if (!isPkCol(pks, f.name)) {
                        try upd_cols_list.append(scratch, f.name);
                    }
                }
                const on_conflict: ?sql.OnConflict = if (ws.mode == .upsert and pks.len > 0) .{
                    .conflict_columns = pks,
                    .action = if (upd_cols_list.items.len > 0)
                        .{ .do_update = upd_cols_list.items }
                    else
                        .do_nothing,
                } else null;

                const vals = try scratch.alloc(sql.SqlValue, first_fields.len);
                for (0..row_count) |row_idx| {
                    const elem = ws.payload.elementAt(row_idx) orelse continue;
                    const fields = try self.extractFields(scratch, ws.table, elem);
                    for (fields, 0..) |f, i| {
                        vals[i] = reflectedToSqlValue(f.value);
                    }
                    const compiled = try sql.compileInsert(sqlite_lib.sqlite_dialect, scratch, .{
                        .table = ws.table,
                        .columns = col_names,
                        .values = vals,
                        .on_conflict = on_conflict,
                    });
                    const stmt = try sqlite_lib.acquireCompiled(&self.stmt_cache, compiled);
                    stmt.execStep() catch |err| {
                        if (err == error.ConstraintViolation and ws.mode == .append) {
                            return error.DuplicatePrimaryKey;
                        }
                        return err;
                    };
                }
            },
            .update => {
                if (pks.len == 0) return error.MissingPrimaryKey;
                for (0..row_count) |row_idx| {
                    const elem = ws.payload.elementAt(row_idx) orelse continue;
                    const fields = try self.extractFields(scratch, ws.table, elem);

                    var assignments: std.ArrayListUnmanaged(sql.Assignment) = .empty;
                    for (fields) |f| {
                        if (isPkCol(pks, f.name)) continue;
                        try assignments.append(scratch, .{
                            .column = f.name,
                            .value = reflectedToSqlValue(f.value),
                        });
                    }
                    const where_expr = try buildPkWhereExpr(scratch, pks, fields);
                    const compiled = try sql.compileUpdate(sqlite_lib.sqlite_dialect, scratch, .{
                        .table = ws.table,
                        .assignments = assignments.items,
                        .where = where_expr,
                    });
                    const stmt = try sqlite_lib.acquireCompiled(&self.stmt_cache, compiled);
                    try stmt.execStep();
                    if (self.db.changes() == 0) return error.RowNotFound;
                }
            },
            .delete => {
                if (pks.len == 0) return error.MissingPrimaryKey;
                for (0..row_count) |row_idx| {
                    const elem = ws.payload.elementAt(row_idx) orelse continue;
                    const fields = try self.extractFields(scratch, ws.table, elem);
                    const where_expr = try buildPkWhereExpr(scratch, pks, fields);
                    const compiled = try sql.compileDelete(sqlite_lib.sqlite_dialect, scratch, .{
                        .table = ws.table,
                        .where = where_expr,
                    });
                    const stmt = try sqlite_lib.acquireCompiled(&self.stmt_cache, compiled);
                    try stmt.execStep();
                }
            },
        }

        if (started_tx) {
            try self.db.commit();
        }
    }

    fn extractFields(self: *const SqliteRepository, allocator: Allocator, table_name: []const u8, elem: PayloadHandle) ![]ReflectedField {
        if (std.mem.endsWith(u8, elem.type_name, "DynamicRecord")) {
            const rec = elem.asScalar(DynamicRecord);
            return @constCast(rec.fields);
        }
        if (self.tables.get(table_name)) |tbl| {
            var list: std.ArrayListUnmanaged(ReflectedField) = .empty;
            for (tbl.columns.entries) |col_entry| {
                if (elem.getReflected(col_entry.key)) |val| {
                    try list.append(allocator, .{ .name = col_entry.key, .value = val });
                }
            }
            return try list.toOwnedSlice(allocator);
        }
        return &.{};
    }

    fn isPkCol(pks: []const []const u8, name: []const u8) bool {
        for (pks) |pk| {
            if (std.mem.eql(u8, pk, name)) return true;
        }
        return false;
    }

    fn findFieldValue(fields: []const ReflectedField, name: []const u8) ?ReflectedValue {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.value;
        }
        return null;
    }

    fn ensureSchemalessTable(self: *SqliteRepository, table_name: []const u8, fields: []const ReflectedField) !void {
        var ddl_buf = std.ArrayListUnmanaged(u8).empty;
        defer ddl_buf.deinit(self.allocator);

        try ddl_buf.appendSlice(self.allocator, "CREATE TABLE IF NOT EXISTS ");
        try appendQuotedIdent(&ddl_buf, self.allocator, table_name);
        try ddl_buf.appendSlice(self.allocator, " (");
        for (fields, 0..) |f, i| {
            if (i > 0) try ddl_buf.appendSlice(self.allocator, ", ");
            try appendQuotedIdent(&ddl_buf, self.allocator, f.name);
            try ddl_buf.append(self.allocator, ' ');
            try ddl_buf.appendSlice(self.allocator, reflectedSqlType(f.value));
        }
        try ddl_buf.appendSlice(self.allocator, ");");
        try self.db.exec(ddl_buf.items);
    }

    fn buildSelectStmt(self: *SqliteRepository, allocator: Allocator, rs: ReadSpec) !Stmt {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const cols: []const []const u8 = switch (rs.projection) {
            .all => &.{},
            .include => |inc| inc,
            .exclude => |excl| blk: {
                if (self.tables.get(rs.table)) |tbl| {
                    var list: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (tbl.columns.entries) |e| {
                        var is_excl = false;
                        for (excl) |ex| {
                            if (std.mem.eql(u8, e.key, ex)) {
                                is_excl = true;
                                break;
                            }
                        }
                        if (!is_excl) try list.append(arena, e.key);
                    }
                    break :blk list.items;
                }
                break :blk &.{};
            },
        };

        const where_expr: ?*const sql.Expr = if (rs.where) |w_ptr| blk: {
            const node: *const PredicateNode = @ptrCast(@alignCast(w_ptr));
            break :blk try predicate_compiler.toSqlExpr(arena, node);
        } else null;

        const order_by = try arena.alloc(sql.OrderBy, rs.order_by.len);
        for (rs.order_by, 0..) |ob, i| {
            order_by[i] = .{
                .column = ob.column,
                .order = if (ob.order == .asc) .asc else .desc,
            };
        }

        const compiled = try sql.compileSelect(sqlite_lib.sqlite_dialect, arena, .{
            .table = rs.table,
            .columns = cols,
            .where = where_expr,
            .order_by = order_by,
            .limit = if (rs.limit > 0) rs.limit else null,
            .offset = if (rs.offset > 0) rs.offset else null,
        });

        return sqlite_lib.prepareCompiled(&self.db, compiled);
    }

    fn rowToDynamicRecord(allocator: Allocator, row: Row) !DynamicRecord {
        const col_count = row.columnCount();
        var fields = try allocator.alloc(ReflectedField, col_count);
        for (0..col_count) |i| {
            fields[i] = .{
                .name = try allocator.dupe(u8, row.columnName(i)),
                .value = try sqliteValueToReflected(allocator, row, i),
            };
        }
        return DynamicRecord.init(fields);
    }

    pub fn read(self: *SqliteRepository, allocator: Allocator, rs: ReadSpec) !PayloadHandle {
        if (!self.schemaless and !self.tables.contains(rs.table)) {
            return error.UnknownTable;
        }
        var stmt = try self.buildSelectStmt(allocator, rs);
        defer stmt.deinit();

        var list: std.ArrayListUnmanaged(DynamicRecord) = .empty;
        while (try stmt.step()) |row| {
            try list.append(allocator, try rowToDynamicRecord(allocator, row));
        }
        const slice = try list.toOwnedSlice(allocator);
        return PayloadHandle.fromSlice(DynamicRecord, slice);
    }

    pub fn readStream(self: *SqliteRepository, allocator: Allocator, rs: ReadSpec) !RowIterator {
        if (!self.schemaless and !self.tables.contains(rs.table)) {
            return error.UnknownTable;
        }
        const stmt = try self.buildSelectStmt(allocator, rs);

        const CursorIter = struct {
            allocator: Allocator,
            stmt: Stmt,
            chunk_arena: std.heap.ArenaAllocator,
            current_row: DynamicRecord = .{ .fields = &.{} },

            fn doNext(ctx: *anyopaque) anyerror!?PayloadHandle {
                const it: *@This() = @ptrCast(@alignCast(ctx));
                _ = it.chunk_arena.reset(.retain_capacity);
                const row = (try it.stmt.step()) orelse return null;
                it.current_row = try rowToDynamicRecord(it.chunk_arena.allocator(), row);
                return PayloadHandle.fromScalar(DynamicRecord, &it.current_row);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const it: *@This() = @ptrCast(@alignCast(ctx));
                it.stmt.deinit();
                it.chunk_arena.deinit();
                it.allocator.destroy(it);
            }

            const vtable = RowIterator.VTable{
                .next = doNext,
                .deinit = doDeinit,
            };
        };

        const iter = try allocator.create(CursorIter);
        iter.* = .{
            .allocator = allocator,
            .stmt = stmt,
            .chunk_arena = std.heap.ArenaAllocator.init(allocator),
        };
        return .{ .ptr = iter, .vtable = &CursorIter.vtable };
    }

    pub fn writePayload(self: *SqliteRepository, table_name: []const u8, payload: PayloadHandle) !void {
        try self.write(.{
            .table = table_name,
            .mode = if (self.tables.contains(table_name)) .upsert else .append,
            .payload = payload,
        });
    }

    pub fn readPayload(self: *SqliteRepository, table_name: []const u8) ?PayloadHandle {
        _ = self;
        _ = table_name;
        return null;
    }

    pub fn recordCount(self: *SqliteRepository, table_name: []const u8) usize {
        var sql_buf: [256]u8 = undefined;
        const count_sql = std.fmt.bufPrint(&sql_buf, "SELECT COUNT(*) FROM \"{s}\";", .{table_name}) catch return 0;

        var stmt = self.db.prepare(count_sql) catch return 0;
        defer stmt.deinit();

        const row = (stmt.step() catch return 0) orelse return 0;
        const cnt = row.int64(0);
        return if (cnt < 0) 0 else @intCast(cnt);
    }

    pub fn beginTx(self: *SqliteRepository) !void {
        try self.db.beginImmediate();
        self.in_tx = true;
    }

    pub fn commit(self: *SqliteRepository) !void {
        try self.db.commit();
        self.in_tx = false;
    }

    pub fn rollback(self: *SqliteRepository) !void {
        try self.db.rollback();
        self.in_tx = false;
    }

    pub fn beginSavepoint(self: *SqliteRepository, name: []const u8) !void {
        _ = try self.db.savepoint(name);
    }

    pub fn rollbackSavepoint(self: *SqliteRepository, name: []const u8) !void {
        var sp = sqlite_lib.Savepoint{ .db = &self.db, .name = name, .active = true };
        sp.rollback();
    }

    pub fn releaseSavepoint(self: *SqliteRepository, name: []const u8) !void {
        var sp = sqlite_lib.Savepoint{ .db = &self.db, .name = name, .active = true };
        try sp.release();
    }

    pub fn storageRepository(self: *SqliteRepository) StorageRepository {
        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                try s.writePayload(channel, payload);
            }
            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                return s.readPayload(channel);
            }
            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                return s.recordCount(channel);
            }
            fn doDeinit(ctx: *anyopaque) void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                const alloc = s.allocator;
                s.deinit();
                alloc.destroy(s);
            }
            fn doGetCapabilities(ctx: *const anyopaque) Capabilities {
                const s: *const SqliteRepository = @ptrCast(@alignCast(ctx));
                return s.getCapabilities();
            }
            fn doEnsureSchema(ctx: *anyopaque, catalog_ptr: *const anyopaque) anyerror!void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                const cat: *const SchemaCatalog = @ptrCast(@alignCast(catalog_ptr));
                try s.ensureSchema(cat);
            }
            fn doWrite(ctx: *anyopaque, ws: WriteSpec) anyerror!void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                try s.write(ws);
            }
            fn doRead(ctx: *anyopaque, alloc: Allocator, rs: ReadSpec) anyerror!PayloadHandle {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                return s.read(alloc, rs);
            }
            fn doReadStream(ctx: *anyopaque, alloc: Allocator, rs: ReadSpec) anyerror!RowIterator {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                return s.readStream(alloc, rs);
            }
            fn doBeginTx(ctx: *anyopaque) anyerror!void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                try s.beginTx();
            }
            fn doCommit(ctx: *anyopaque) anyerror!void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                try s.commit();
            }
            fn doRollback(ctx: *anyopaque) anyerror!void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                try s.rollback();
            }
            fn doBeginSavepoint(ctx: *anyopaque, name: []const u8) anyerror!void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                try s.beginSavepoint(name);
            }
            fn doRollbackSavepoint(ctx: *anyopaque, name: []const u8) anyerror!void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                try s.rollbackSavepoint(name);
            }
            fn doReleaseSavepoint(ctx: *anyopaque, name: []const u8) anyerror!void {
                const s: *SqliteRepository = @ptrCast(@alignCast(ctx));
                try s.releaseSavepoint(name);
            }

            const vtable = StorageRepository.VTable{
                .writePayload = &doWritePayload,
                .readPayload = &doReadPayload,
                .recordCount = &doRecordCount,
                .deinit = &doDeinit,
                .getCapabilities = &doGetCapabilities,
                .ensureSchema = &doEnsureSchema,
                .write = &doWrite,
                .read = &doRead,
                .readStream = &doReadStream,
                .beginTx = &doBeginTx,
                .commit = &doCommit,
                .rollback = &doRollback,
                .beginSavepoint = &doBeginSavepoint,
                .rollbackSavepoint = &doRollbackSavepoint,
                .releaseSavepoint = &doReleaseSavepoint,
            };
        };

        return .{
            .ptr = self,
            .vtable = &Trampoline.vtable,
        };
    }

    pub fn createHeap(allocator: Allocator, params: []const ConfigParam) anyerror!StorageRepository {
        var db_path: []const u8 = ":memory:";
        var schema_path: ?[]const u8 = null;
        var schemaless: bool = false;
        var migrate_mode: MigrateMode = .auto;
        var opts = OpenOptions{
            .journal_mode = .wal,
            .synchronous = .normal,
        };

        for (params) |p| {
            if (std.mem.eql(u8, p.key, "path")) {
                db_path = p.value;
            } else if (std.mem.eql(u8, p.key, "schema")) {
                schema_path = p.value;
            } else if (std.mem.eql(u8, p.key, "read_only")) {
                opts.read_only = std.mem.eql(u8, p.value, "true");
            } else if (std.mem.eql(u8, p.key, "schemaless")) {
                schemaless = std.mem.eql(u8, p.value, "true");
            } else if (std.mem.eql(u8, p.key, "migrate")) {
                if (std.mem.eql(u8, p.value, "verify")) migrate_mode = .verify else if (std.mem.eql(u8, p.value, "off")) migrate_mode = .off else migrate_mode = .auto;
            } else if (std.mem.eql(u8, p.key, "busy_timeout_ms")) {
                opts.busy_timeout_ms = std.fmt.parseInt(u32, p.value, 10) catch 5000;
            } else if (std.mem.eql(u8, p.key, "journal_mode")) {
                if (std.mem.eql(u8, p.key, "wal")) opts.journal_mode = .wal else if (std.mem.eql(u8, p.value, "memory")) opts.journal_mode = .memory else if (std.mem.eql(u8, p.value, "delete")) opts.journal_mode = .delete;
            } else if (std.mem.eql(u8, p.key, "synchronous")) {
                if (std.mem.eql(u8, p.value, "normal")) opts.synchronous = .normal else if (std.mem.eql(u8, p.value, "full")) opts.synchronous = .full else if (std.mem.eql(u8, p.value, "off")) opts.synchronous = .off;
            }
        }

        const is_mem = std.mem.eql(u8, db_path, ":memory:");
        if (is_mem) {
            opts.journal_mode = .memory;
            opts.pragma.auto_vacuum = null;
        } else {
            opts.pragma.auto_vacuum = .incremental;
        }

        var opened_db = if (is_mem)
            try Db.openMemory(opts)
        else
            try Db.openFile(allocator, db_path, opts);
        errdefer opened_db.close();

        const self_ptr = try allocator.create(SqliteRepository);
        errdefer allocator.destroy(self_ptr);

        self_ptr.* = SqliteRepository.initWithConfig(allocator, opened_db, schemaless, migrate_mode);

        if (schema_path) |spath| {
            errdefer self_ptr.schema_arena.deinit();
            errdefer self_ptr.tables.deinit(allocator);
            const bytes = try flowdata.readFileBytes(allocator, spath);
            defer allocator.free(bytes);
            const arena = self_ptr.schema_arena.allocator();

            const catalog = try flowdata.yaml.parseSchemaCatalog(arena, bytes, null);
            try self_ptr.ensureSchema(&catalog);
        }

        return self_ptr.storageRepository();
    }
};
