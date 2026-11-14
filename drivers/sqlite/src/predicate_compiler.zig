const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const predicate_ast = flowdata.dataflow.predicate_ast;
const PredicateNode = predicate_ast.PredicateNode;
const Literal = predicate_ast.Literal;
const CmpOp = predicate_ast.CmpOp;
const sqlite_lib = @import("flowdata_sqlite");
const Value = sqlite_lib.Value;

pub const CompiledPredicate = struct {
    sql_where: []const u8,
    bindings: []const Value,

    pub fn deinit(self: CompiledPredicate, allocator: Allocator) void {
        allocator.free(self.sql_where);
        allocator.free(self.bindings);
    }
};

fn literalToValue(lit: Literal) Value {
    return switch (lit) {
        .null_val => .null_val,
        .int64 => |v| .{ .int64 = v },
        .float64 => |v| .{ .float64 = v },
        .boolean => |v| .{ .boolean = v },
        .text => |v| .{ .text = v },
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

fn emitNode(
    allocator: Allocator,
    node: *const PredicateNode,
    buf: *std.ArrayListUnmanaged(u8),
    bindings: *std.ArrayListUnmanaged(Value),
) !void {
    switch (node.*) {
        .@"and" => |bin| {
            try buf.append(allocator, '(');
            try emitNode(allocator, bin.left, buf, bindings);
            try buf.appendSlice(allocator, " AND ");
            try emitNode(allocator, bin.right, buf, bindings);
            try buf.append(allocator, ')');
        },
        .@"or" => |bin| {
            try buf.append(allocator, '(');
            try emitNode(allocator, bin.left, buf, bindings);
            try buf.appendSlice(allocator, " OR ");
            try emitNode(allocator, bin.right, buf, bindings);
            try buf.append(allocator, ')');
        },
        .not => |inner| {
            try buf.appendSlice(allocator, "NOT (");
            try emitNode(allocator, inner, buf, bindings);
            try buf.append(allocator, ')');
        },
        .cmp => |c| {
            try appendQuotedIdent(buf, allocator, c.column);
            if (c.value == .null_val) {
                switch (c.op) {
                    .eq => try buf.appendSlice(allocator, " IS NULL"),
                    .ne => try buf.appendSlice(allocator, " IS NOT NULL"),
                    else => {
                        const op_str: []const u8 = switch (c.op) {
                            .lt => " < ",
                            .lte => " <= ",
                            .gt => " > ",
                            .gte => " >= ",
                            else => unreachable,
                        };
                        try buf.appendSlice(allocator, op_str);
                        try bindings.append(allocator, .null_val);
                        var idx_buf: [24]u8 = undefined;
                        const ph = try std.fmt.bufPrint(&idx_buf, "?{d}", .{bindings.items.len});
                        try buf.appendSlice(allocator, ph);
                    },
                }
                return;
            }
            const op_str = switch (c.op) {
                .eq => " = ",
                .ne => " != ",
                .lt => " < ",
                .lte => " <= ",
                .gt => " > ",
                .gte => " >= ",
            };
            try buf.appendSlice(allocator, op_str);
            try bindings.append(allocator, literalToValue(c.value));
            var idx_buf: [24]u8 = undefined;
            const ph = try std.fmt.bufPrint(&idx_buf, "?{d}", .{bindings.items.len});
            try buf.appendSlice(allocator, ph);
        },
        .is_null => |col| {
            try appendQuotedIdent(buf, allocator, col);
            try buf.appendSlice(allocator, " IS NULL");
        },
        .is_not_null => |col| {
            try appendQuotedIdent(buf, allocator, col);
            try buf.appendSlice(allocator, " IS NOT NULL");
        },
        .in_list => |inl| {
            if (inl.values.len == 0) {
                try buf.appendSlice(allocator, "0 = 1");
                return;
            }
            try appendQuotedIdent(buf, allocator, inl.column);
            try buf.appendSlice(allocator, " IN (");
            for (inl.values, 0..) |v, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try bindings.append(allocator, literalToValue(v));
                var idx_buf: [24]u8 = undefined;
                const ph = try std.fmt.bufPrint(&idx_buf, "?{d}", .{bindings.items.len});
                try buf.appendSlice(allocator, ph);
            }
            try buf.append(allocator, ')');
        },
        .literal => |b| {
            try buf.appendSlice(allocator, if (b) "1 = 1" else "0 = 1");
        },
    }
}

/// Compiles a `PredicateNode` AST into a parameterized SQL `WHERE` expression
/// (without the leading `WHERE ` keyword) and positional `?1 .. ?N` bindings.
pub fn compile(allocator: Allocator, node: *const PredicateNode) !CompiledPredicate {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var bindings: std.ArrayListUnmanaged(Value) = .empty;
    errdefer bindings.deinit(allocator);

    try emitNode(allocator, node, &buf, &bindings);
    return .{
        .sql_where = try buf.toOwnedSlice(allocator),
        .bindings = try bindings.toOwnedSlice(allocator),
    };
}

