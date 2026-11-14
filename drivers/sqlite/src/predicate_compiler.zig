const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const predicate_ast = flowdata.dataflow.predicate_ast;
const PredicateNode = predicate_ast.PredicateNode;
const Literal = predicate_ast.Literal;
const CmpOp = predicate_ast.CmpOp;
const sql = @import("flowdata_sql");
const sqlite_lib = @import("flowdata_sqlite");

fn literalToSqlValue(lit: Literal) sql.SqlValue {
    return switch (lit) {
        .null_val => .null_val,
        .int64 => |v| .{ .int64 = v },
        .float64 => |v| .{ .float64 = v },
        .boolean => |v| .{ .boolean = v },
        .text => |v| .{ .text = v },
    };
}

fn mapCmpOp(op: CmpOp) sql.CmpOp {
    return switch (op) {
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .lte => .lte,
        .gt => .gt,
        .gte => .gte,
    };
}

/// Converts a Flowdata `PredicateNode` AST into a portable `sql.Expr` AST
/// using `arena` for child node allocations (zero SQL string building).
pub fn toSqlExpr(arena: Allocator, node: *const PredicateNode) !*const sql.Expr {
    const out = try arena.create(sql.Expr);
    out.* = switch (node.*) {
        .@"and" => |bin| .{ .@"and" = .{
            .left = try toSqlExpr(arena, bin.left),
            .right = try toSqlExpr(arena, bin.right),
        } },
        .@"or" => |bin| .{ .@"or" = .{
            .left = try toSqlExpr(arena, bin.left),
            .right = try toSqlExpr(arena, bin.right),
        } },
        .not => |inner| .{ .not = try toSqlExpr(arena, inner) },
        .cmp => |c| .{ .cmp = .{
            .column = c.column,
            .op = mapCmpOp(c.op),
            .value = literalToSqlValue(c.value),
        } },
        .is_null => |col| .{ .is_null = col },
        .is_not_null => |col| .{ .is_not_null = col },
        .in_list => |inl| blk: {
            const vals = try arena.alloc(sql.SqlValue, inl.values.len);
            for (inl.values, 0..) |v, i| vals[i] = literalToSqlValue(v);
            break :blk .{ .in_list = .{ .column = inl.column, .values = vals } };
        },
        .literal => |b| .{ .literal = b },
    };
    return out;
}

/// Convenience helper: converts `PredicateNode` to `sql.Expr` and compiles to SQLite SQL.
pub fn compile(allocator: Allocator, node: *const PredicateNode) !sql.CompiledQuery {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const expr = try toSqlExpr(arena_state.allocator(), node);
    return sql.compileExpr(sqlite_lib.sqlite_dialect, allocator, expr);
}
