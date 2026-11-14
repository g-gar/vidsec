const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Dialect = @import("dialect.zig").Dialect;
const SqlValue = ast.SqlValue;
const Expr = ast.Expr;
const SelectQuery = ast.SelectQuery;
const InsertQuery = ast.InsertQuery;
const UpdateQuery = ast.UpdateQuery;
const DeleteQuery = ast.DeleteQuery;
const Query = ast.Query;

pub const CompiledQuery = struct {
    sql: []const u8,
    bindings: []const SqlValue,

    pub fn deinit(self: CompiledQuery, allocator: Allocator) void {
        allocator.free(self.sql);
        allocator.free(self.bindings);
    }
};

fn appendQuotedIdent(dialect: Dialect, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, ident: []const u8) !void {
    const q = dialect.identQuote();
    try buf.append(allocator, q);
    for (ident) |ch| {
        if (ch == q) {
            try buf.append(allocator, q);
            try buf.append(allocator, q);
        } else {
            try buf.append(allocator, ch);
        }
    }
    try buf.append(allocator, q);
}

fn emitExpr(
    dialect: Dialect,
    allocator: Allocator,
    expr: *const Expr,
    buf: *std.ArrayListUnmanaged(u8),
    bindings: *std.ArrayListUnmanaged(SqlValue),
) !void {
    switch (expr.*) {
        .@"and" => |bin| {
            try buf.append(allocator, '(');
            try emitExpr(dialect, allocator, bin.left, buf, bindings);
            try buf.appendSlice(allocator, " AND ");
            try emitExpr(dialect, allocator, bin.right, buf, bindings);
            try buf.append(allocator, ')');
        },
        .@"or" => |bin| {
            try buf.append(allocator, '(');
            try emitExpr(dialect, allocator, bin.left, buf, bindings);
            try buf.appendSlice(allocator, " OR ");
            try emitExpr(dialect, allocator, bin.right, buf, bindings);
            try buf.append(allocator, ')');
        },
        .not => |inner| {
            try buf.appendSlice(allocator, "NOT (");
            try emitExpr(dialect, allocator, inner, buf, bindings);
            try buf.append(allocator, ')');
        },
        .cmp => |c| {
            try appendQuotedIdent(dialect, buf, allocator, c.column);
            if (c.value == .null_val) {
                switch (c.op) {
                    .eq => {
                        try buf.appendSlice(allocator, " IS NULL");
                        return;
                    },
                    .ne => {
                        try buf.appendSlice(allocator, " IS NOT NULL");
                        return;
                    },
                    else => {},
                }
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
            try bindings.append(allocator, c.value);
            try dialect.writePlaceholder(buf, allocator, bindings.items.len);
        },
        .is_null => |col| {
            try appendQuotedIdent(dialect, buf, allocator, col);
            try buf.appendSlice(allocator, " IS NULL");
        },
        .is_not_null => |col| {
            try appendQuotedIdent(dialect, buf, allocator, col);
            try buf.appendSlice(allocator, " IS NOT NULL");
        },
        .in_list => |inl| {
            if (inl.values.len == 0) {
                try buf.appendSlice(allocator, "0 = 1");
                return;
            }
            try appendQuotedIdent(dialect, buf, allocator, inl.column);
            try buf.appendSlice(allocator, " IN (");
            for (inl.values, 0..) |v, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try bindings.append(allocator, v);
                try dialect.writePlaceholder(buf, allocator, bindings.items.len);
            }
            try buf.append(allocator, ')');
        },
        .literal => |b| {
            try buf.appendSlice(allocator, if (b) "1 = 1" else "0 = 1");
        },
    }
}

pub fn compileExpr(dialect: Dialect, allocator: Allocator, expr: *const Expr) !CompiledQuery {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var bindings: std.ArrayListUnmanaged(SqlValue) = .empty;
    errdefer bindings.deinit(allocator);

    try emitExpr(dialect, allocator, expr, &buf, &bindings);
    return .{
        .sql = try buf.toOwnedSlice(allocator),
        .bindings = try bindings.toOwnedSlice(allocator),
    };
}

pub fn compileSelect(dialect: Dialect, allocator: Allocator, q: SelectQuery) !CompiledQuery {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var bindings: std.ArrayListUnmanaged(SqlValue) = .empty;
    errdefer bindings.deinit(allocator);

    try buf.appendSlice(allocator, "SELECT ");
    if (q.columns.len == 0) {
        try buf.append(allocator, '*');
    } else {
        for (q.columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try appendQuotedIdent(dialect, &buf, allocator, col);
        }
    }

    try buf.appendSlice(allocator, " FROM ");
    try appendQuotedIdent(dialect, &buf, allocator, q.table);

    if (q.where) |w| {
        try buf.appendSlice(allocator, " WHERE ");
        try emitExpr(dialect, allocator, w, &buf, &bindings);
    }

    if (q.order_by.len > 0) {
        try buf.appendSlice(allocator, " ORDER BY ");
        for (q.order_by, 0..) |ob, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try appendQuotedIdent(dialect, &buf, allocator, ob.column);
            try buf.appendSlice(allocator, if (ob.order == .asc) " ASC" else " DESC");
        }
    }

    if (q.limit) |lim| {
        var lim_buf: [32]u8 = undefined;
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&lim_buf, " LIMIT {d}", .{lim}));
        if (q.offset) |off| {
            var off_buf: [32]u8 = undefined;
            try buf.appendSlice(allocator, try std.fmt.bufPrint(&off_buf, " OFFSET {d}", .{off}));
        }
    } else if (q.offset) |off| {
        var off_buf: [64]u8 = undefined;
        if (dialect.offset_only_limit) |lim| {
            try buf.appendSlice(allocator, try std.fmt.bufPrint(&off_buf, " LIMIT {d} OFFSET {d}", .{ lim, off }));
        } else {
            try buf.appendSlice(allocator, try std.fmt.bufPrint(&off_buf, " OFFSET {d}", .{off}));
        }
    }

    try buf.append(allocator, ';');
    return .{
        .sql = try buf.toOwnedSlice(allocator),
        .bindings = try bindings.toOwnedSlice(allocator),
    };
}

pub fn compileInsert(dialect: Dialect, allocator: Allocator, q: InsertQuery) !CompiledQuery {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var bindings: std.ArrayListUnmanaged(SqlValue) = .empty;
    errdefer bindings.deinit(allocator);

    if (q.or_ignore) {
        switch (dialect.insert_ignore) {
            .ignore_prefix => try buf.appendSlice(allocator, "INSERT IGNORE INTO "),
            .or_ignore_prefix => try buf.appendSlice(allocator, "INSERT OR IGNORE INTO "),
            .on_conflict_do_nothing_suffix => try buf.appendSlice(allocator, "INSERT INTO "),
        }
    } else {
        try buf.appendSlice(allocator, "INSERT INTO ");
    }

    try appendQuotedIdent(dialect, &buf, allocator, q.table);
    try buf.appendSlice(allocator, " (");
    for (q.columns, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try appendQuotedIdent(dialect, &buf, allocator, col);
    }
    try buf.appendSlice(allocator, ") VALUES (");
    for (q.values, 0..) |val, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try bindings.append(allocator, val);
        try dialect.writePlaceholder(&buf, allocator, bindings.items.len);
    }
    try buf.append(allocator, ')');

    if (q.on_conflict) |oc| {
        switch (dialect.upsert) {
            .on_conflict_excluded => {
                try buf.appendSlice(allocator, " ON CONFLICT(");
                for (oc.conflict_columns, 0..) |pk, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try appendQuotedIdent(dialect, &buf, allocator, pk);
                }
                switch (oc.action) {
                    .do_nothing => try buf.appendSlice(allocator, ") DO NOTHING"),
                    .do_update => |upd_cols| {
                        if (upd_cols.len == 0) {
                            try buf.appendSlice(allocator, ") DO NOTHING");
                        } else {
                            try buf.appendSlice(allocator, ") DO UPDATE SET ");
                            for (upd_cols, 0..) |col, i| {
                                if (i > 0) try buf.appendSlice(allocator, ", ");
                                try appendQuotedIdent(dialect, &buf, allocator, col);
                                try buf.appendSlice(allocator, " = excluded.");
                                try appendQuotedIdent(dialect, &buf, allocator, col);
                            }
                        }
                    },
                }
            },
            .on_duplicate_key_values => {
                switch (oc.action) {
                    .do_nothing => {},
                    .do_update => |upd_cols| {
                        if (upd_cols.len > 0) {
                            try buf.appendSlice(allocator, " ON DUPLICATE KEY UPDATE ");
                            for (upd_cols, 0..) |col, i| {
                                if (i > 0) try buf.appendSlice(allocator, ", ");
                                try appendQuotedIdent(dialect, &buf, allocator, col);
                                try buf.appendSlice(allocator, " = VALUES(");
                                try appendQuotedIdent(dialect, &buf, allocator, col);
                                try buf.append(allocator, ')');
                            }
                        }
                    },
                }
            },
        }
    } else if (q.or_ignore and dialect.insert_ignore == .on_conflict_do_nothing_suffix) {
        try buf.appendSlice(allocator, " ON CONFLICT DO NOTHING");
    }

    try buf.append(allocator, ';');
    return .{
        .sql = try buf.toOwnedSlice(allocator),
        .bindings = try bindings.toOwnedSlice(allocator),
    };
}

pub fn compileUpdate(dialect: Dialect, allocator: Allocator, q: UpdateQuery) !CompiledQuery {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var bindings: std.ArrayListUnmanaged(SqlValue) = .empty;
    errdefer bindings.deinit(allocator);

    try buf.appendSlice(allocator, "UPDATE ");
    try appendQuotedIdent(dialect, &buf, allocator, q.table);
    try buf.appendSlice(allocator, " SET ");

    for (q.assignments, 0..) |a, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try appendQuotedIdent(dialect, &buf, allocator, a.column);
        try buf.appendSlice(allocator, " = ");
        try bindings.append(allocator, a.value);
        try dialect.writePlaceholder(&buf, allocator, bindings.items.len);
    }

    if (q.where) |w| {
        try buf.appendSlice(allocator, " WHERE ");
        try emitExpr(dialect, allocator, w, &buf, &bindings);
    }

    try buf.append(allocator, ';');
    return .{
        .sql = try buf.toOwnedSlice(allocator),
        .bindings = try bindings.toOwnedSlice(allocator),
    };
}

pub fn compileDelete(dialect: Dialect, allocator: Allocator, q: DeleteQuery) !CompiledQuery {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var bindings: std.ArrayListUnmanaged(SqlValue) = .empty;
    errdefer bindings.deinit(allocator);

    try buf.appendSlice(allocator, "DELETE FROM ");
    try appendQuotedIdent(dialect, &buf, allocator, q.table);

    if (q.where) |w| {
        try buf.appendSlice(allocator, " WHERE ");
        try emitExpr(dialect, allocator, w, &buf, &bindings);
    }

    try buf.append(allocator, ';');
    return .{
        .sql = try buf.toOwnedSlice(allocator),
        .bindings = try bindings.toOwnedSlice(allocator),
    };
}

pub fn compile(dialect: Dialect, allocator: Allocator, query: Query) !CompiledQuery {
    return switch (query) {
        .select => |s| compileSelect(dialect, allocator, s),
        .insert => |ins| compileInsert(dialect, allocator, ins),
        .update => |upd| compileUpdate(dialect, allocator, upd),
        .delete => |del| compileDelete(dialect, allocator, del),
    };
}

