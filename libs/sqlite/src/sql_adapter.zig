const std = @import("std");
const sql = @import("flowdata_sql");
const db_mod = @import("db.zig");
const stmt_cache = @import("stmt_cache.zig");

const Db = db_mod.Db;
const Stmt = db_mod.Stmt;
const Value = db_mod.Value;
const StmtCache = stmt_cache.StmtCache;

/// SQLite-specific `sql.Dialect` configuration supplied to `flowdata_sql`.
pub const sqlite_dialect: sql.Dialect = .{
    .ident_quote = '"',
    .placeholder = .{ .indexed = "?" },
    .offset_only_limit = -1,
    .insert_ignore = .or_ignore_prefix,
    .upsert = .on_conflict_excluded,
};

pub fn toSqliteValue(v: sql.SqlValue) Value {
    return switch (v) {
        .null_val => .null_val,
        .int64 => |x| .{ .int64 = x },
        .float64 => |x| .{ .float64 = x },
        .boolean => |x| .{ .boolean = x },
        .text => |x| .{ .text = x },
        .blob => |x| .{ .blob = x },
    };
}

pub fn bindCompiled(stmt: *Stmt, bindings: []const sql.SqlValue) db_mod.SqliteError!void {
    for (bindings, 1..) |v, idx| {
        try stmt.bindValue(idx, toSqliteValue(v));
    }
}

/// Prepares a `sql.CompiledQuery` on `db` and binds all positional parameters.
pub fn prepareCompiled(db: *Db, compiled: sql.CompiledQuery) db_mod.SqliteError!Stmt {
    var stmt = try db.prepare(compiled.sql);
    errdefer stmt.deinit();
    try bindCompiled(&stmt, compiled.bindings);
    return stmt;
}

/// Acquires a cached `Stmt` for `compiled.sql` from `cache` and binds all parameters.
pub fn acquireCompiled(cache: *StmtCache, compiled: sql.CompiledQuery) !*Stmt {
    const stmt = try cache.acquire(compiled.sql);
    try bindCompiled(stmt, compiled.bindings);
    return stmt;
}

test "ARCH-009D: libs/sqlite sql_adapter executes CompiledQuery" {
    const testing = std.testing;
    var db = try Db.openMemory(.{});
    defer db.close();

    try db.execZ("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT) STRICT;");

    const ins = try sql.compileInsert(sqlite_dialect, testing.allocator, .{
        .table = "items",
        .columns = &.{ "id", "name" },
        .values = &.{ .{ .int64 = 1 }, .{ .text = "alpha" } },
    });
    defer ins.deinit(testing.allocator);

    var ins_stmt = try prepareCompiled(&db, ins);
    defer ins_stmt.deinit();
    try ins_stmt.execStep();

    const sel = try sql.compileSelect(sqlite_dialect, testing.allocator, .{
        .table = "items",
        .columns = &.{"name"},
        .where = &sql.Expr{ .cmp = .{ .column = "id", .op = .eq, .value = .{ .int64 = 1 } } },
    });
    defer sel.deinit(testing.allocator);

    var sel_stmt = try prepareCompiled(&db, sel);
    defer sel_stmt.deinit();
    const row = (try sel_stmt.step()).?;
    try testing.expectEqualStrings("alpha", row.text(0));
}

