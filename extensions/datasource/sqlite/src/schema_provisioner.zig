const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const SchemaCatalog = flowdata.yaml.SchemaCatalog;
const TableSchema = flowdata.yaml.TableSchema;
const ColumnSpec = flowdata.yaml.ColumnSpec;
const ColumnType = flowdata.yaml.ColumnType;
const ForeignKeyAction = flowdata.yaml.schema_loader.ForeignKeyAction;
const sqlite_lib = @import("sqlite_lib/mod.zig");
const Db = sqlite_lib.Db;
const ddl = sqlite_lib.ddl;

fn mapColType(t: ColumnType) ddl.StorageType {
    return switch (t) {
        .int64, .bool => .integer,
        .float64 => .real,
        .text => .text,
        .blob => .blob,
        .any => .any,
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

/// Translates a format-agnostic `SchemaCatalog` into SQLite DDL and executes it on `db`.
pub fn provisionCatalog(allocator: Allocator, db: *Db, catalog: *const SchemaCatalog) !void {
    for (catalog.schemas.entries) |dom_entry| {
        for (dom_entry.value.entries) |tbl_entry| {
            try provisionTable(allocator, db, tbl_entry.key, &tbl_entry.value);
        }
    }
}

fn provisionTable(allocator: Allocator, db: *Db, table_name: []const u8, tbl: *const TableSchema) !void {
    var ddl_builder = ddl.DdlBuilder.init(allocator);
    defer ddl_builder.deinit();

    // 1. Build column definitions
    var cols = try allocator.alloc(ddl.ColumnDef, tbl.columns.count());
    defer allocator.free(cols);

    for (tbl.columns.entries, 0..) |col_entry, idx| {
        const c_spec = col_entry.value;
        const fk_spec: ?ddl.ForeignKeyRefSpec = if (c_spec.ref) |r| .{
            .table = r.table,
            .column = r.column,
            .on_delete = mapFkAction(c_spec.on_delete),
            .on_update = mapFkAction(c_spec.on_update),
        } else null;

        const def_val: ?ddl.DefaultSpec = if (c_spec.default_raw) |raw|
            .{ .raw_expr = raw }
        else if (c_spec.default_expr) |expr|
            .{ .raw_expr = expr }
        else
            null;

        cols[idx] = .{
            .name = col_entry.key,
            .storage_type = mapColType(c_spec.col_type),
            .primary_key = c_spec.pk and tbl.primary_key.len == 0,
            .autoincrement = c_spec.autoincrement,
            .not_null = !c_spec.nullable,
            .unique = c_spec.unique and !c_spec.pk,
            .default_val = def_val,
            .references = fk_spec,
        };
    }

    // 2. Build constraints (composite primary key if defined)
    var constraints_list: std.ArrayListUnmanaged(ddl.TableConstraint) = .empty;
    defer constraints_list.deinit(allocator);

    if (tbl.primary_key.len > 0) {
        try constraints_list.append(allocator, .{
            .primary_key = .{
                .columns = tbl.primary_key,
            },
        });
    }

    const table_def = ddl.TableDef{
        .name = table_name,
        .if_not_exists = true,
        .strict = false, // Allow flexibility with reflected dynamic records
        .without_rowid = tbl.without_rowid,
        .columns = cols,
        .constraints = constraints_list.items,
    };

    try ddl_builder.addCreateTable(table_def);

    // 3. Build secondary indexes
    for (tbl.indexes) |idx_spec| {
        if (idx_spec.columns.len == 0) continue;

        var idx_cols = try allocator.alloc(ddl.IndexColumn, idx_spec.columns.len);
        defer allocator.free(idx_cols);

        var name_buf = std.ArrayListUnmanaged(u8).empty;
        defer name_buf.deinit(allocator);
        try name_buf.appendSlice(allocator, "idx_");
        try name_buf.appendSlice(allocator, table_name);

        for (idx_spec.columns, 0..) |col_name, ci| {
            idx_cols[ci] = .{
                .name_or_expr = col_name,
                .is_expr = false,
            };
            try name_buf.append(allocator, '_');
            try name_buf.appendSlice(allocator, col_name);
        }

        const index_def = ddl.IndexDef{
            .name = idx_spec.name orelse name_buf.items,
            .table = table_name,
            .unique = idx_spec.unique,
            .if_not_exists = true,
            .columns = idx_cols,
            .where_expr = idx_spec.where,
        };

        try ddl_builder.addCreateIndex(index_def);
    }

    // 4. Execute generated DDL on database
    try db.exec(ddl_builder.buf.items);

    // 5. Execute seed inserts if declared
    if (tbl.seeds.len > 0) {
        if (try tbl.renderSeedInsertSql(allocator, table_name)) |seeds_sql| {
            defer allocator.free(seeds_sql);
            try db.exec(seeds_sql);
        }
    }
}
