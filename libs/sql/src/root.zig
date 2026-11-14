pub const ast = @import("ast.zig");
pub const dialect = @import("dialect.zig");
pub const compiler = @import("compiler.zig");

pub const SqlValue = ast.SqlValue;
pub const CmpOp = ast.CmpOp;
pub const SortOrder = ast.SortOrder;
pub const OrderBy = ast.OrderBy;
pub const Expr = ast.Expr;
pub const SelectQuery = ast.SelectQuery;
pub const OnConflict = ast.OnConflict;
pub const InsertQuery = ast.InsertQuery;
pub const Assignment = ast.Assignment;
pub const UpdateQuery = ast.UpdateQuery;
pub const DeleteQuery = ast.DeleteQuery;
pub const Query = ast.Query;

pub const PlaceholderStyle = dialect.PlaceholderStyle;
pub const InsertIgnoreStyle = dialect.InsertIgnoreStyle;
pub const UpsertStyle = dialect.UpsertStyle;
pub const Dialect = dialect.Dialect;
pub const CompiledQuery = compiler.CompiledQuery;
pub const compile = compiler.compile;
pub const compileExpr = compiler.compileExpr;
pub const compileSelect = compiler.compileSelect;
pub const compileInsert = compiler.compileInsert;
pub const compileUpdate = compiler.compileUpdate;
pub const compileDelete = compiler.compileDelete;

const std = @import("std");

test "ARCH-009D: compile SelectQuery across dialect capability configs" {
    const testing = std.testing;
    const where_expr = Expr{
        .@"and" = .{
            .left = &Expr{ .cmp = .{ .column = "status", .op = .eq, .value = .{ .text = "active" } } },
            .right = &Expr{ .cmp = .{ .column = "age", .op = .gte, .value = .{ .int64 = 18 } } },
        },
    };
    const q = SelectQuery{
        .table = "users",
        .columns = &.{ "id", "name" },
        .where = &where_expr,
        .order_by = &.{.{ .column = "age", .order = .desc }},
        .limit = 10,
        .offset = 5,
    };

    const indexed_q: Dialect = .{
        .ident_quote = '"',
        .placeholder = .{ .indexed = "?" },
        .offset_only_limit = -1,
    };
    const sq = try compileSelect(indexed_q, testing.allocator, q);
    defer sq.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "SELECT \"id\", \"name\" FROM \"users\" WHERE (\"status\" = ?1 AND \"age\" >= ?2) ORDER BY \"age\" DESC LIMIT 10 OFFSET 5;",
        sq.sql,
    );
    try testing.expectEqual(@as(usize, 2), sq.bindings.len);

    const indexed_dollar: Dialect = .{
        .ident_quote = '"',
        .placeholder = .{ .indexed = "$" },
    };
    const pg = try compileSelect(indexed_dollar, testing.allocator, q);
    defer pg.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "SELECT \"id\", \"name\" FROM \"users\" WHERE (\"status\" = $1 AND \"age\" >= $2) ORDER BY \"age\" DESC LIMIT 10 OFFSET 5;",
        pg.sql,
    );

    const backtick_anon: Dialect = .{
        .ident_quote = '`',
        .placeholder = .{ .anonymous = "?" },
        .offset_only_limit = -1,
    };
    const my = try compileSelect(backtick_anon, testing.allocator, q);
    defer my.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "SELECT `id`, `name` FROM `users` WHERE (`status` = ? AND `age` >= ?) ORDER BY `age` DESC LIMIT 10 OFFSET 5;",
        my.sql,
    );
}

test "ARCH-009D: compile InsertQuery upsert across dialect capability configs" {
    const testing = std.testing;
    const q = InsertQuery{
        .table = "users",
        .columns = &.{ "id", "name" },
        .values = &.{ .{ .int64 = 1 }, .{ .text = "Alice" } },
        .on_conflict = .{
            .conflict_columns = &.{"id"},
            .action = .{ .do_update = &.{"name"} },
        },
    };

    const excluded_dialect: Dialect = .{
        .ident_quote = '"',
        .placeholder = .{ .indexed = "?" },
        .upsert = .on_conflict_excluded,
    };
    const sq = try compileInsert(excluded_dialect, testing.allocator, q);
    defer sq.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "INSERT INTO \"users\" (\"id\", \"name\") VALUES (?1, ?2) ON CONFLICT(\"id\") DO UPDATE SET \"name\" = excluded.\"name\";",
        sq.sql,
    );

    const dup_key_dialect: Dialect = .{
        .ident_quote = '`',
        .placeholder = .{ .anonymous = "?" },
        .upsert = .on_duplicate_key_values,
    };
    const my = try compileInsert(dup_key_dialect, testing.allocator, q);
    defer my.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "INSERT INTO `users` (`id`, `name`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `name` = VALUES(`name`);",
        my.sql,
    );
}

