const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const schema = flowdata.schema;
const SchemaCatalog = schema.SchemaCatalog;
const TableSchema = schema.TableSchema;
const ColumnSpec = schema.ColumnSpec;
const ColumnType = schema.ColumnType;
const ForeignKeyAction = schema.ForeignKeyAction;
const sqlite_lib = @import("flowdata_sqlite");
const Db = sqlite_lib.Db;
const Value = sqlite_lib.Value;
const ddl = sqlite_lib.ddl;

pub const MigrateMode = enum {
    auto,
    verify,
    off,
};

pub const ProvisionError = error{
    DestructiveSchemaDrift,
    SchemaDriftDetected,
};

fn mapColType(t: ColumnType) ddl.StorageType {
    return switch (t) {
        .int64, .uint64, .bool, .timestamp => .integer,
        .float64 => .real,
        .text, .json, .enum_type, .any => .text,
        .bytes, .blob => .blob,
    };
}

fn storageTypeName(t: ddl.StorageType) []const u8 {
    return switch (t) {
        .integer => "INTEGER",
        .real => "REAL",
        .text => "TEXT",
        .blob => "BLOB",
        .any => "ANY",
    };
}

fn mapFkAction(act: ?ForeignKeyAction) ?ddl.ForeignKeyAction {
    const a = act orelse return null;
    return switch (a) {
        .no_action => .no_action,
        .restrict => .restrict,
        .set_null => .set_null,
        .set_default => .set_default,
        .cascade => .cascade,
    };
}

fn buildDefaultSpec(c_spec: ColumnSpec) ?ddl.DefaultSpec {
    if (c_spec.default_expr) |expr| return .{ .raw_expr = expr };
    const raw = c_spec.default_raw orelse return null;
    if (std.mem.eql(u8, raw, "null")) return .{ .raw_expr = "NULL" };
    return switch (c_spec.col_type) {
        .int64, .uint64, .timestamp, .float64 => .{ .raw_expr = raw },
        .bool => .{ .raw_expr = if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) "1" else "0" },
        .text, .json, .enum_type, .any, .bytes, .blob => .{ .text = raw },
    };
}

fn buildColumnDef(col_name: []const u8, c_spec: ColumnSpec, table_pk_len: usize) ddl.ColumnDef {
    const fk_spec: ?ddl.ForeignKeyRefSpec = if (c_spec.ref) |r| .{
        .table = r.table,
        .column = r.column,
        .on_delete = mapFkAction(c_spec.on_delete),
        .on_update = mapFkAction(c_spec.on_update),
    } else null;

    const gen_spec: ?ddl.GeneratedColumnSpec = if (c_spec.generated_as) |expr| .{
        .expr = expr,
        .storage = if (c_spec.stored) .stored else .virtual,
    } else null;

    return .{
        .name = col_name,
        .storage_type = mapColType(c_spec.col_type),
        .primary_key = c_spec.pk and table_pk_len == 0,
        .autoincrement = c_spec.autoincrement,
        .not_null = !c_spec.nullable,
        .unique = c_spec.unique and !c_spec.pk,
        .default_val = buildDefaultSpec(c_spec),
        .check_expr = c_spec.check,
        .collate = c_spec.collate,
        .generated = gen_spec,
        .references = fk_spec,
    };
}

/// Translates a format-agnostic `SchemaCatalog` into SQLite DDL, executes
/// Phase 1 non-destructive migrations, seeds rows via parameterized statements,
/// and records schema metadata in `_flowdata_schema`.
pub fn provisionCatalogWithMode(
    allocator: Allocator,
    db: *Db,
    catalog: *const SchemaCatalog,
    mode: MigrateMode,
) !void {
    if (mode == .off) return;

    if (mode == .auto) {
        try db.execZ(
            \\CREATE TABLE IF NOT EXISTS "_flowdata_schema" (
            \\    "table_name" TEXT PRIMARY KEY,
            \\    "schema_hash" TEXT NOT NULL,
            \\    "updated_at" INTEGER NOT NULL
            \\) STRICT;
        );
        var ver_buf: [64]u8 = undefined;
        const ver_sql = try std.fmt.bufPrint(&ver_buf, "PRAGMA user_version = {d};", .{catalog.version});
        try db.exec(ver_sql);
    }

    for (catalog.schemas.entries) |dom_entry| {
        for (dom_entry.value.entries) |tbl_entry| {
            try provisionTable(allocator, db, tbl_entry.key, &tbl_entry.value, mode);
        }
    }
}

/// Backward-compatible default (`MigrateMode.auto`).
pub fn provisionCatalog(allocator: Allocator, db: *Db, catalog: *const SchemaCatalog) !void {
    try provisionCatalogWithMode(allocator, db, catalog, .auto);
}

const ExistingColumn = struct {
    name: []const u8,
    col_type: []const u8,
    pk: bool,
};

fn inspectExistingTable(allocator: Allocator, db: *Db, table_name: []const u8) !?[]ExistingColumn {
    var exists_stmt = try db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1;");
    defer exists_stmt.deinit();
    try exists_stmt.bindText(1, table_name);
    if ((try exists_stmt.step()) == null) return null;

    var pragma_buf: [256]u8 = undefined;
    const pragma_sql = try std.fmt.bufPrint(&pragma_buf, "PRAGMA table_info(\"{s}\");", .{table_name});
    var info_stmt = try db.prepare(pragma_sql);
    defer info_stmt.deinit();

    var cols: std.ArrayListUnmanaged(ExistingColumn) = .empty;
    errdefer {
        for (cols.items) |col| {
            allocator.free(col.name);
            allocator.free(col.col_type);
        }
        cols.deinit(allocator);
    }

    while (try info_stmt.step()) |row| {
        const name = try allocator.dupe(u8, row.text(1));
        errdefer allocator.free(name);
        const col_type = try allocator.dupe(u8, row.text(2));
        errdefer allocator.free(col_type);
        const pk = row.int64(5) > 0;
        try cols.append(allocator, .{ .name = name, .col_type = col_type, .pk = pk });
    }
    return try cols.toOwnedSlice(allocator);
}

fn freeExistingColumns(allocator: Allocator, cols: []ExistingColumn) void {
    for (cols) |col| {
        allocator.free(col.name);
        allocator.free(col.col_type);
    }
    allocator.free(cols);
}

fn computeTableHash(tbl: *const TableSchema) [16]u8 {
    var hasher = std.hash.Wyhash.init(0);
    for (tbl.columns.entries) |e| {
        hasher.update(e.key);
        hasher.update(@tagName(e.value.col_type));
        hasher.update(if (e.value.pk) "1" else "0");
        hasher.update(if (e.value.nullable) "1" else "0");
    }
    for (tbl.primary_key) |pk| hasher.update(pk);
    const digest = hasher.final();
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{digest}) catch unreachable;
    return out;
}

fn provisionTable(
    allocator: Allocator,
    db: *Db,
    table_name: []const u8,
    tbl: *const TableSchema,
    mode: MigrateMode,
) !void {
    const existing_opt = try inspectExistingTable(allocator, db, table_name);
    if (existing_opt) |existing_cols| {
        defer freeExistingColumns(allocator, existing_cols);

        // Phase 1 Migration Check: detect destructive drift vs safe additive columns
        for (existing_cols) |ex| {
            const target = tbl.findColumn(ex.name) orelse {
                std.log.warn("[SQLite migrate] Destructive drift on '{s}': column '{s}' was dropped", .{ table_name, ex.name });
                return error.DestructiveSchemaDrift;
            };
            const expected_type = storageTypeName(mapColType(target.col_type));
            if (!std.ascii.eqlIgnoreCase(ex.col_type, expected_type)) {
                std.log.warn("[SQLite migrate] Destructive drift on '{s}.{s}': expected type {s}, found {s}", .{
                    table_name,
                    ex.name,
                    expected_type,
                    ex.col_type,
                });
                return error.DestructiveSchemaDrift;
            }
            const is_pk = target.pk or blk: {
                for (tbl.primary_key) |pk_col| {
                    if (std.mem.eql(u8, pk_col, ex.name)) break :blk true;
                }
                break :blk false;
            };
            if (ex.pk != is_pk) {
                std.log.warn("[SQLite migrate] Destructive drift on '{s}.{s}': primary key changed", .{ table_name, ex.name });
                return error.DestructiveSchemaDrift;
            }
        }

        // Additive columns
        for (tbl.columns.entries) |col_entry| {
            var found = false;
            for (existing_cols) |ex| {
                if (std.mem.eql(u8, ex.name, col_entry.key)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;

            const c_spec = col_entry.value;
            if (!c_spec.nullable and c_spec.default_raw == null and c_spec.default_expr == null) {
                std.log.warn("[SQLite migrate] Cannot add NOT NULL column '{s}.{s}' without a default", .{ table_name, col_entry.key });
                return error.DestructiveSchemaDrift;
            }
            if (mode == .verify) return error.SchemaDriftDetected;

            var alter_builder = ddl.DdlBuilder.init(allocator);
            defer alter_builder.deinit();
            try alter_builder.addAlterTableAddColumn(
                table_name,
                buildColumnDef(col_entry.key, c_spec, tbl.primary_key.len),
            );
            try db.exec(alter_builder.buf.items);
        }

        // Ensure secondary indexes exist
        try ensureTableIndexes(allocator, db, table_name, tbl);
    } else {
        if (mode == .verify) return error.SchemaDriftDetected;

        var ddl_builder = ddl.DdlBuilder.init(allocator);
        defer ddl_builder.deinit();

        var cols = try allocator.alloc(ddl.ColumnDef, tbl.columns.count());
        defer allocator.free(cols);

        for (tbl.columns.entries, 0..) |col_entry, idx| {
            cols[idx] = buildColumnDef(col_entry.key, col_entry.value, tbl.primary_key.len);
        }

        var constraints_list: std.ArrayListUnmanaged(ddl.TableConstraint) = .empty;
        defer constraints_list.deinit(allocator);

        if (tbl.primary_key.len > 0) {
            try constraints_list.append(allocator, .{ .primary_key = .{ .columns = tbl.primary_key } });
        }
        for (tbl.unique_keys) |uk_cols| {
            try constraints_list.append(allocator, .{ .unique = .{ .columns = uk_cols } });
        }
        for (tbl.checks) |chk| {
            try constraints_list.append(allocator, .{ .check = .{ .expr = chk } });
        }

        try ddl_builder.addCreateTable(.{
            .name = table_name,
            .temp = tbl.temp,
            .if_not_exists = true,
            .strict = tbl.strict,
            .without_rowid = tbl.without_rowid,
            .columns = cols,
            .constraints = constraints_list.items,
        });

        try db.exec(ddl_builder.buf.items);
        try ensureTableIndexes(allocator, db, table_name, tbl);
    }

    if (mode == .auto) {
        const hash = computeTableHash(tbl);
        var meta_stmt = try db.prepare(
            \\INSERT INTO "_flowdata_schema" ("table_name", "schema_hash", "updated_at")
            \\VALUES (?1, ?2, ?3)
            \\ON CONFLICT("table_name") DO UPDATE SET
            \\    "schema_hash" = excluded."schema_hash",
            \\    "updated_at" = excluded."updated_at";
        );
        defer meta_stmt.deinit();
        try meta_stmt.bindText(1, table_name);
        try meta_stmt.bindText(2, &hash);
        var ts: std.c.timespec = undefined;
        const now_sec: i64 = if (std.c.clock_gettime(.REALTIME, &ts) == 0) @intCast(ts.sec) else 0;
        try meta_stmt.bindInt64(3, now_sec);
        try meta_stmt.execStep();
    }

    // Parameterized seed inserts (never raw SQL concatenation)
    if (tbl.seeds.len > 0 and mode == .auto) {
        try executeParameterizedSeeds(allocator, db, table_name, tbl);
    }
}

fn ensureTableIndexes(allocator: Allocator, db: *Db, table_name: []const u8, tbl: *const TableSchema) !void {
    if (tbl.indexes.len == 0) return;

    var ddl_builder = ddl.DdlBuilder.init(allocator);
    defer ddl_builder.deinit();

    for (tbl.indexes, 0..) |idx_spec, idx_i| {
        const total = idx_spec.columns.len + idx_spec.expressions.len;
        if (total == 0) continue;

        var idx_cols = try allocator.alloc(ddl.IndexColumn, total);
        defer allocator.free(idx_cols);

        var name_buf = std.ArrayListUnmanaged(u8).empty;
        defer name_buf.deinit(allocator);
        try name_buf.appendSlice(allocator, "idx_");
        try name_buf.appendSlice(allocator, table_name);

        const order: ?ddl.SortOrder = if (idx_spec.order) |o| switch (o) {
            .asc => .asc,
            .desc => .desc,
        } else null;

        var ci: usize = 0;
        for (idx_spec.columns) |col_name| {
            idx_cols[ci] = .{ .name_or_expr = col_name, .is_expr = false, .order = order };
            ci += 1;
            try name_buf.append(allocator, '_');
            try name_buf.appendSlice(allocator, col_name);
        }
        for (idx_spec.expressions) |expr| {
            idx_cols[ci] = .{ .name_or_expr = expr, .is_expr = true, .order = order };
            ci += 1;
        }
        if (idx_spec.columns.len == 0) {
            var num_buf: [16]u8 = undefined;
            const suf = try std.fmt.bufPrint(&num_buf, "_expr_{d}", .{idx_i});
            try name_buf.appendSlice(allocator, suf);
        }

        try ddl_builder.addCreateIndex(.{
            .name = idx_spec.name orelse name_buf.items,
            .table = table_name,
            .unique = idx_spec.unique,
            .if_not_exists = true,
            .columns = idx_cols,
            .where_expr = idx_spec.where,
        });
    }

    if (ddl_builder.buf.items.len > 0) {
        try db.exec(ddl_builder.buf.items);
    }
}

fn executeParameterizedSeeds(
    allocator: Allocator,
    db: *Db,
    table_name: []const u8,
    tbl: *const TableSchema,
) !void {
    for (tbl.seeds) |seed_row| {
        if (seed_row.entries.len == 0) continue;

        var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer sql_buf.deinit(allocator);

        try sql_buf.appendSlice(allocator, "INSERT OR IGNORE INTO \"");
        try sql_buf.appendSlice(allocator, table_name);
        try sql_buf.appendSlice(allocator, "\" (");

        for (seed_row.entries, 0..) |entry, i| {
            if (i > 0) try sql_buf.appendSlice(allocator, ", ");
            try sql_buf.append(allocator, '"');
            try sql_buf.appendSlice(allocator, entry.key);
            try sql_buf.append(allocator, '"');
        }
        try sql_buf.appendSlice(allocator, ") VALUES (");
        for (seed_row.entries, 0..) |_, i| {
            if (i > 0) try sql_buf.appendSlice(allocator, ", ");
            var ph_buf: [16]u8 = undefined;
            const ph = try std.fmt.bufPrint(&ph_buf, "?{d}", .{i + 1});
            try sql_buf.appendSlice(allocator, ph);
        }
        try sql_buf.appendSlice(allocator, ");");

        var stmt = try db.prepare(sql_buf.items);
        defer stmt.deinit();

        for (seed_row.entries, 1..) |entry, param_idx| {
            const col_spec = tbl.columns.get(entry.key);
            const col_type = if (col_spec) |c| c.col_type else ColumnType.text;
            const raw_val = entry.value.value;

            const val: Value = if (std.mem.eql(u8, raw_val, "null") and entry.value.quote_style == .plain)
                .null_val
            else switch (col_type) {
                .int64, .uint64, .timestamp => .{
                    .int64 = std.fmt.parseInt(i64, raw_val, 10) catch return error.InvalidDefaultValue,
                },
                .float64 => .{
                    .float64 = std.fmt.parseFloat(f64, raw_val) catch return error.InvalidDefaultValue,
                },
                .bool => .{
                    .boolean = std.mem.eql(u8, raw_val, "true") or std.mem.eql(u8, raw_val, "1"),
                },
                .text, .json, .enum_type, .bytes, .blob, .any => .{ .text = raw_val },
            };
            try stmt.bindValue(param_idx, val);
        }
        try stmt.execStep();
    }
}
