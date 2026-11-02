const std = @import("std");
const Allocator = std.mem.Allocator;
const ddl = @import("ddl.zig");

pub const QueryBuildError = error{
    EmptyProjections,
    EmptyFromClause,
    EmptyMutationColumns,
    EmptyKeyColumns,
    EmptyUpdateSetColumns,
    MissingKeyColumnInMutation,
    InvalidExpression,
    OutOfMemory,
} || ddl.DdlError;

pub const CteSpec = struct {
    name: []const u8,
    columns: []const []const u8 = &.{},
    query_sql: []const u8,
    materialized: ?bool = null,
};

pub const Projection = struct {
    /// Column name or arbitrary SQL expression (e.g. `payload_offset` or `effective_end_offset - payload_offset`).
    expr: []const u8,
    /// Optional `AS "<alias>"` name.
    alias: ?[]const u8 = null,
};

pub const JoinKind = enum {
    inner,
    left,
    cross,

    pub fn toSql(self: JoinKind) []const u8 {
        return switch (self) {
            .inner => "INNER JOIN",
            .left => "LEFT JOIN",
            .cross => "CROSS JOIN",
        };
    }
};

pub const JoinConstraint = union(enum) {
    none,
    on_expr: []const u8,
    using_columns: []const []const u8,
};

pub const JoinClause = struct {
    kind: JoinKind = .inner,
    table_or_subquery: []const u8,
    is_subquery: bool = false,
    alias: ?[]const u8 = null,
    constraint: JoinConstraint = .none,
};

pub const OrderByTerm = struct {
    expr: []const u8,
    order: ?ddl.SortOrder = null,
    nulls: ?ddl.NullsOrder = null,
};

pub const CompoundOperator = enum {
    union_all,
    union_distinct,
    intersect,
    except,

    pub fn toSql(self: CompoundOperator) []const u8 {
        return switch (self) {
            .union_all => "UNION ALL",
            .union_distinct => "UNION",
            .intersect => "INTERSECT",
            .except => "EXCEPT",
        };
    }
};

pub const CompoundSelect = struct {
    op: CompoundOperator,
    select_sql: []const u8,
};

/// Full-fledged declarative `SELECT` query specification.
pub const SelectQuery = struct {
    recursive_cte: bool = false,
    ctes: []const CteSpec = &.{},
    distinct: bool = false,
    projections: []const Projection,
    from_table_or_subquery: []const u8,
    from_is_subquery: bool = false,
    from_alias: ?[]const u8 = null,
    joins: []const JoinClause = &.{},
    where_clauses: []const []const u8 = &.{},
    group_by: []const []const u8 = &.{},
    having_expr: ?[]const u8 = null,
    compounds: []const CompoundSelect = &.{},
    order_by: []const OrderByTerm = &.{},
    limit: ?u64 = null,
    offset: ?u64 = null,

    pub fn toSql(self: SelectQuery, allocator: Allocator) QueryBuildError![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        try self.writeSql(&buf, allocator);
        return buf.toOwnedSlice(allocator);
    }

    pub fn toSqlZ(self: SelectQuery, allocator: Allocator) QueryBuildError![:0]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        try self.writeSql(&buf, allocator);
        return buf.toOwnedSliceSentinel(allocator, 0);
    }

    pub fn writeSql(self: SelectQuery, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) QueryBuildError!void {
        if (self.projections.len == 0) return error.EmptyProjections;
        if (self.from_table_or_subquery.len == 0) return error.EmptyFromClause;

        if (self.ctes.len > 0) {
            try buf.appendSlice(allocator, "WITH ");
            if (self.recursive_cte) try buf.appendSlice(allocator, "RECURSIVE ");
            for (self.ctes, 0..) |cte, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try ddl.writeQuotedIdent(buf, allocator, cte.name);
                if (cte.columns.len > 0) {
                    try buf.appendSlice(allocator, " (");
                    try ddl.writeIdentList(buf, allocator, cte.columns);
                    try buf.append(allocator, ')');
                }
                try buf.appendSlice(allocator, " AS ");
                if (cte.materialized) |mat| {
                    try buf.appendSlice(allocator, if (mat) "MATERIALIZED (" else "NOT MATERIALIZED (");
                } else {
                    try buf.append(allocator, '(');
                }
                try buf.appendSlice(allocator, std.mem.trim(u8, cte.query_sql, " \t\r\n;"));
                try buf.append(allocator, ')');
            }
            try buf.append(allocator, ' ');
        }

        try buf.appendSlice(allocator, "SELECT ");
        if (self.distinct) try buf.appendSlice(allocator, "DISTINCT ");

        for (self.projections, 0..) |proj, i| {
            const expr_trimmed = std.mem.trim(u8, proj.expr, " \t\r\n");
            if (expr_trimmed.len == 0) return error.InvalidExpression;
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, expr_trimmed);
            if (proj.alias) |alias_name| {
                try buf.appendSlice(allocator, " AS ");
                try ddl.writeQuotedIdent(buf, allocator, alias_name);
            }
        }

        try buf.appendSlice(allocator, " FROM ");
        if (self.from_is_subquery) {
            try buf.append(allocator, '(');
            try buf.appendSlice(allocator, std.mem.trim(u8, self.from_table_or_subquery, " \t\r\n;"));
            try buf.append(allocator, ')');
        } else {
            try ddl.writeQuotedIdent(buf, allocator, self.from_table_or_subquery);
        }
        if (self.from_alias) |fa| {
            try buf.appendSlice(allocator, " AS ");
            try ddl.writeQuotedIdent(buf, allocator, fa);
        }

        for (self.joins) |j| {
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, j.kind.toSql());
            try buf.append(allocator, ' ');
            if (j.is_subquery) {
                try buf.append(allocator, '(');
                try buf.appendSlice(allocator, std.mem.trim(u8, j.table_or_subquery, " \t\r\n;"));
                try buf.append(allocator, ')');
            } else {
                try ddl.writeQuotedIdent(buf, allocator, j.table_or_subquery);
            }
            if (j.alias) |ja| {
                try buf.appendSlice(allocator, " AS ");
                try ddl.writeQuotedIdent(buf, allocator, ja);
            }
            switch (j.constraint) {
                .none => {},
                .on_expr => |on_sql| {
                    try buf.appendSlice(allocator, " ON (");
                    try buf.appendSlice(allocator, on_sql);
                    try buf.append(allocator, ')');
                },
                .using_columns => |ucols| {
                    try buf.appendSlice(allocator, " USING (");
                    try ddl.writeIdentList(buf, allocator, ucols);
                    try buf.append(allocator, ')');
                },
            }
        }

        var written_where = false;
        for (self.where_clauses) |raw_cond| {
            const cond = std.mem.trim(u8, raw_cond, " \t\r\n");
            if (cond.len == 0) continue;
            if (!written_where) {
                try buf.appendSlice(allocator, " WHERE (");
                written_where = true;
            } else {
                try buf.appendSlice(allocator, " AND (");
            }
            try buf.appendSlice(allocator, cond);
            try buf.append(allocator, ')');
        }

        if (self.group_by.len > 0) {
            try buf.appendSlice(allocator, " GROUP BY ");
            for (self.group_by, 0..) |gb, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, gb);
            }
        }

        if (self.having_expr) |hav| {
            const h_trim = std.mem.trim(u8, hav, " \t\r\n");
            if (h_trim.len > 0) {
                try buf.appendSlice(allocator, " HAVING (");
                try buf.appendSlice(allocator, h_trim);
                try buf.append(allocator, ')');
            }
        }

        for (self.compounds) |comp| {
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, comp.op.toSql());
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, std.mem.trim(u8, comp.select_sql, " \t\r\n;"));
        }

        if (self.order_by.len > 0) {
            try buf.appendSlice(allocator, " ORDER BY ");
            for (self.order_by, 0..) |ob, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, ob.expr);
                if (ob.order) |ord| {
                    try buf.append(allocator, ' ');
                    try buf.appendSlice(allocator, ord.toSql());
                }
                if (ob.nulls) |nl| {
                    try buf.append(allocator, ' ');
                    try buf.appendSlice(allocator, nl.toSql());
                }
            }
        }

        if (self.limit) |lim| {
            var num_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, " LIMIT {d}", .{lim}) catch unreachable;
            try buf.appendSlice(allocator, s);
        }

        if (self.offset) |off| {
            var num_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, " OFFSET {d}", .{off}) catch unreachable;
            try buf.appendSlice(allocator, s);
        }
    }
};

/// Value source for a column in a parameterized `INSERT`, `UPSERT`, or `UPDATE` statement.
pub const ColumnValueExpr = union(enum) {
    /// Positional SQLite bind parameter `?1`, `?2`, ... (1-based).
    bind_param: usize,
    /// Constant SQL string literal (escaped safely as `'...'`).
    literal_text: []const u8,
    /// Constant SQL integer literal.
    literal_int64: i64,
    /// Constant SQL float literal.
    literal_float64: f64,
    /// Constant SQL boolean literal (`1` or `0`).
    literal_bool: bool,
    /// Constant `NULL`.
    literal_null,
    /// Raw SQL expression (e.g. `CURRENT_TIMESTAMP`).
    raw_expr: []const u8,

    pub fn writeSql(self: ColumnValueExpr, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
        switch (self) {
            .bind_param => |idx| {
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "?{d}", .{idx}) catch unreachable;
                try buf.appendSlice(allocator, s);
            },
            .literal_text => |txt| try ddl.writeSqlStringLiteral(buf, allocator, txt),
            .literal_int64 => |v| {
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{v}) catch unreachable;
                try buf.appendSlice(allocator, s);
            },
            .literal_float64 => |v| {
                var num_buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{v}) catch unreachable;
                try buf.appendSlice(allocator, s);
            },
            .literal_bool => |v| try buf.appendSlice(allocator, if (v) "1" else "0"),
            .literal_null => try buf.appendSlice(allocator, "NULL"),
            .raw_expr => |expr| try buf.appendSlice(allocator, expr),
        }
    }
};

pub const ColumnAssignment = struct {
    column: []const u8,
    value: ColumnValueExpr,
};

pub const MutationKind = union(enum) {
    insert: struct {
        or_conflict: ?ddl.ConflictResolution = null,
    },
    upsert: struct {
        conflict_columns: []const []const u8,
        where_expr: ?[]const u8 = null,
    },
    update: struct {
        key_columns: []const []const u8,
        extra_where_expr: ?[]const u8 = null,
    },
};

/// Full-fledged parameterized `INSERT` / `UPSERT` / `UPDATE` builder.
pub const MutationQuery = struct {
    table: []const u8,
    kind: MutationKind,
    assignments: []const ColumnAssignment,
    returning_columns: []const []const u8 = &.{},

    pub fn toSql(self: MutationQuery, allocator: Allocator) QueryBuildError![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        try self.writeSql(&buf, allocator);
        return buf.toOwnedSlice(allocator);
    }

    pub fn toSqlZ(self: MutationQuery, allocator: Allocator) QueryBuildError![:0]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        try self.writeSql(&buf, allocator);
        return buf.toOwnedSliceSentinel(allocator, 0);
    }

    pub fn writeSql(self: MutationQuery, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) QueryBuildError!void {
        if (self.table.len == 0) return error.EmptyTableName;
        if (self.assignments.len == 0) return error.EmptyMutationColumns;

        switch (self.kind) {
            .insert => |ins| {
                try buf.appendSlice(allocator, "INSERT ");
                if (ins.or_conflict) |conf| {
                    try buf.appendSlice(allocator, "OR ");
                    try buf.appendSlice(allocator, conf.toSql());
                    try buf.append(allocator, ' ');
                }
                try buf.appendSlice(allocator, "INTO ");
                try ddl.writeQuotedIdent(buf, allocator, self.table);
                try buf.appendSlice(allocator, " (");
                for (self.assignments, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try ddl.writeQuotedIdent(buf, allocator, a.column);
                }
                try buf.appendSlice(allocator, ") VALUES (");
                for (self.assignments, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try a.value.writeSql(buf, allocator);
                }
                try buf.append(allocator, ')');
            },
            .upsert => |ups| {
                if (ups.conflict_columns.len == 0) return error.EmptyKeyColumns;
                for (ups.conflict_columns) |kcol| {
                    if (!hasAssignment(self.assignments, kcol)) {
                        return error.MissingKeyColumnInMutation;
                    }
                }

                try buf.appendSlice(allocator, "INSERT INTO ");
                try ddl.writeQuotedIdent(buf, allocator, self.table);
                try buf.appendSlice(allocator, " (");
                for (self.assignments, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try ddl.writeQuotedIdent(buf, allocator, a.column);
                }
                try buf.appendSlice(allocator, ") VALUES (");
                for (self.assignments, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try a.value.writeSql(buf, allocator);
                }
                try buf.appendSlice(allocator, ") ON CONFLICT (");
                try ddl.writeIdentList(buf, allocator, ups.conflict_columns);
                try buf.appendSlice(allocator, ") DO ");

                var non_key_count: usize = 0;
                for (self.assignments) |a| {
                    if (!sliceContainsStr(ups.conflict_columns, a.column)) {
                        non_key_count += 1;
                    }
                }

                if (non_key_count == 0) {
                    try buf.appendSlice(allocator, "NOTHING");
                } else {
                    try buf.appendSlice(allocator, "UPDATE SET ");
                    var written: usize = 0;
                    for (self.assignments) |a| {
                        if (sliceContainsStr(ups.conflict_columns, a.column)) continue;
                        if (written > 0) try buf.appendSlice(allocator, ", ");
                        try ddl.writeQuotedIdent(buf, allocator, a.column);
                        try buf.appendSlice(allocator, " = excluded.");
                        try ddl.writeQuotedIdent(buf, allocator, a.column);
                        written += 1;
                    }
                    if (ups.where_expr) |w| {
                        if (w.len > 0) {
                            try buf.appendSlice(allocator, " WHERE ");
                            try buf.appendSlice(allocator, w);
                        }
                    }
                }
            },
            .update => |upd| {
                if (upd.key_columns.len == 0) return error.EmptyKeyColumns;
                for (upd.key_columns) |kcol| {
                    if (!hasAssignment(self.assignments, kcol)) {
                        return error.MissingKeyColumnInMutation;
                    }
                }

                var non_key_count: usize = 0;
                for (self.assignments) |a| {
                    if (!sliceContainsStr(upd.key_columns, a.column)) {
                        non_key_count += 1;
                    }
                }
                if (non_key_count == 0) return error.EmptyUpdateSetColumns;

                try buf.appendSlice(allocator, "UPDATE ");
                try ddl.writeQuotedIdent(buf, allocator, self.table);
                try buf.appendSlice(allocator, " SET ");

                var written: usize = 0;
                for (self.assignments) |a| {
                    if (sliceContainsStr(upd.key_columns, a.column)) continue;
                    if (written > 0) try buf.appendSlice(allocator, ", ");
                    try ddl.writeQuotedIdent(buf, allocator, a.column);
                    try buf.appendSlice(allocator, " = ");
                    try a.value.writeSql(buf, allocator);
                    written += 1;
                }

                try buf.appendSlice(allocator, " WHERE ");
                var key_written: usize = 0;
                for (self.assignments) |a| {
                    if (!sliceContainsStr(upd.key_columns, a.column)) continue;
                    if (key_written > 0) try buf.appendSlice(allocator, " AND ");
                    try ddl.writeQuotedIdent(buf, allocator, a.column);
                    try buf.appendSlice(allocator, " = ");
                    try a.value.writeSql(buf, allocator);
                    key_written += 1;
                }

                if (upd.extra_where_expr) |w| {
                    if (w.len > 0) {
                        try buf.appendSlice(allocator, " AND (");
                        try buf.appendSlice(allocator, w);
                        try buf.append(allocator, ')');
                    }
                }
            },
        }

        if (self.returning_columns.len > 0) {
            try buf.appendSlice(allocator, " RETURNING ");
            try ddl.writeIdentList(buf, allocator, self.returning_columns);
        }

        try buf.append(allocator, ';');
    }
};

/// Builds `INSERT INTO "target_table" ("col1", "col2", ...) <select_sql>;`.
pub fn buildInsertFromSelect(
    allocator: Allocator,
    target_table: []const u8,
    target_columns: []const []const u8,
    select_sql: []const u8,
) QueryBuildError![]u8 {
    if (target_table.len == 0) return error.EmptyTableName;
    const select_trimmed = std.mem.trim(u8, select_sql, " \t\r\n;");
    if (select_trimmed.len == 0) return error.InvalidExpression;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "INSERT INTO ");
    try ddl.writeQuotedIdent(&buf, allocator, target_table);
    if (target_columns.len > 0) {
        try buf.appendSlice(allocator, " (");
        try ddl.writeIdentList(&buf, allocator, target_columns);
        try buf.append(allocator, ')');
    }
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, select_trimmed);
    try buf.append(allocator, ';');

    return buf.toOwnedSlice(allocator);
}

fn hasAssignment(assignments: []const ColumnAssignment, col_name: []const u8) bool {
    for (assignments) |a| {
        if (std.mem.eql(u8, a.column, col_name)) return true;
    }
    return false;
}

fn sliceContainsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}
