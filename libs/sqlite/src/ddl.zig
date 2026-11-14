const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DdlError = error{
    EmptyTableName,
    EmptyColumnName,
    EmptyTableColumns,
    EmptyIndexName,
    EmptyIndexColumns,
    EmptyViewName,
    EmptyViewSelect,
    EmptyTriggerName,
    EmptyTriggerBody,
    InvalidIdentifier,
    AutoincrementRequiresIntegerPrimaryKey,
    WithoutRowidIncompatibleWithAutoincrement,
    ForeignKeyColumnCountMismatch,
    OutOfMemory,
};

/// SQLite `STRICT` table storage classes.
pub const StorageType = enum {
    integer,
    real,
    text,
    blob,
    any,

    pub fn toSql(self: StorageType) []const u8 {
        return switch (self) {
            .integer => "INTEGER",
            .real => "REAL",
            .text => "TEXT",
            .blob => "BLOB",
            .any => "ANY",
        };
    }
};

pub const SortOrder = enum {
    asc,
    desc,

    pub fn toSql(self: SortOrder) []const u8 {
        return switch (self) {
            .asc => "ASC",
            .desc => "DESC",
        };
    }
};

pub const NullsOrder = enum {
    first,
    last,

    pub fn toSql(self: NullsOrder) []const u8 {
        return switch (self) {
            .first => "NULLS FIRST",
            .last => "NULLS LAST",
        };
    }
};

pub const ConflictResolution = enum {
    rollback,
    abort,
    fail,
    ignore,
    replace,

    pub fn toSql(self: ConflictResolution) []const u8 {
        return switch (self) {
            .rollback => "ROLLBACK",
            .abort => "ABORT",
            .fail => "FAIL",
            .ignore => "IGNORE",
            .replace => "REPLACE",
        };
    }
};

pub const ForeignKeyAction = enum {
    no_action,
    restrict,
    set_null,
    set_default,
    cascade,

    pub fn toSql(self: ForeignKeyAction) []const u8 {
        return switch (self) {
            .no_action => "NO ACTION",
            .restrict => "RESTRICT",
            .set_null => "SET NULL",
            .set_default => "SET DEFAULT",
            .cascade => "CASCADE",
        };
    }
};

pub const DefaultSpec = union(enum) {
    null_val,
    int64: i64,
    float64: f64,
    boolean: bool,
    text: []const u8,
    blob: []const u8,
    /// Raw SQL expression (wrapped in parentheses if not already parenthesized, e.g. `CURRENT_TIMESTAMP` or `0`).
    raw_expr: []const u8,
};

pub const GeneratedStorage = enum {
    virtual,
    stored,

    pub fn toSql(self: GeneratedStorage) []const u8 {
        return switch (self) {
            .virtual => "VIRTUAL",
            .stored => "STORED",
        };
    }
};

pub const GeneratedColumnSpec = struct {
    expr: []const u8,
    storage: GeneratedStorage = .virtual,
};

pub const ForeignKeyRefSpec = struct {
    table: []const u8,
    column: []const u8,
    on_delete: ?ForeignKeyAction = null,
    on_update: ?ForeignKeyAction = null,
    deferrable_initially_deferred: bool = false,
};

/// Full column specification for `CREATE TABLE`.
pub const ColumnDef = struct {
    name: []const u8,
    storage_type: StorageType,
    primary_key: bool = false,
    pk_order: ?SortOrder = null,
    pk_conflict: ?ConflictResolution = null,
    autoincrement: bool = false,
    not_null: bool = true,
    unique: bool = false,
    unique_conflict: ?ConflictResolution = null,
    default_val: ?DefaultSpec = null,
    check_expr: ?[]const u8 = null,
    collate: ?[]const u8 = null,
    generated: ?GeneratedColumnSpec = null,
    references: ?ForeignKeyRefSpec = null,
};

/// Table-level constraints (composite primary keys, composite unique constraints, composite foreign keys, checks).
pub const TableConstraint = union(enum) {
    primary_key: struct {
        name: ?[]const u8 = null,
        columns: []const []const u8,
        conflict: ?ConflictResolution = null,
    },
    unique: struct {
        name: ?[]const u8 = null,
        columns: []const []const u8,
        conflict: ?ConflictResolution = null,
    },
    check: struct {
        name: ?[]const u8 = null,
        expr: []const u8,
    },
    foreign_key: struct {
        name: ?[]const u8 = null,
        from_columns: []const []const u8,
        target_table: []const u8,
        target_columns: []const []const u8,
        on_delete: ?ForeignKeyAction = null,
        on_update: ?ForeignKeyAction = null,
        deferrable_initially_deferred: bool = false,
    },
};

/// Full `CREATE [TEMP] TABLE [IF NOT EXISTS] ... [STRICT] [WITHOUT ROWID]` specification.
pub const TableDef = struct {
    name: []const u8,
    temp: bool = false,
    if_not_exists: bool = true,
    strict: bool = true,
    without_rowid: bool = false,
    columns: []const ColumnDef,
    constraints: []const TableConstraint = &.{},
};

pub const IndexColumn = struct {
    /// Column name (quoted as identifier when `is_expr == false`) or SQL expression (written verbatim in `(...)` when `is_expr == true`).
    name_or_expr: []const u8,
    is_expr: bool = false,
    collate: ?[]const u8 = null,
    order: ?SortOrder = null,
};

/// Full `CREATE [UNIQUE] INDEX [IF NOT EXISTS] ... ON table (...) [WHERE ...]` specification.
pub const IndexDef = struct {
    name: []const u8,
    table: []const u8,
    unique: bool = false,
    if_not_exists: bool = true,
    columns: []const IndexColumn,
    where_expr: ?[]const u8 = null,
};

/// Full `CREATE [TEMP] VIEW [IF NOT EXISTS] ... AS SELECT ...` specification.
pub const ViewDef = struct {
    name: []const u8,
    temp: bool = false,
    if_not_exists: bool = true,
    columns: []const []const u8 = &.{},
    select_sql: []const u8,
};

pub const TriggerTiming = enum {
    before,
    after,
    instead_of,

    pub fn toSql(self: TriggerTiming) []const u8 {
        return switch (self) {
            .before => "BEFORE",
            .after => "AFTER",
            .instead_of => "INSTEAD OF",
        };
    }
};

pub const TriggerEvent = union(enum) {
    insert,
    delete,
    update: []const []const u8,
};

/// Full `CREATE [TEMP] TRIGGER [IF NOT EXISTS] ...` specification.
pub const TriggerDef = struct {
    name: []const u8,
    temp: bool = false,
    if_not_exists: bool = true,
    timing: TriggerTiming,
    event: TriggerEvent,
    table: []const u8,
    for_each_row: bool = true,
    when_expr: ?[]const u8 = null,
    body_sql: []const u8,
};

/// Full-fledged SQLite DDL Builder & Emitter.
pub const DdlBuilder = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) DdlBuilder {
        return .{
            .buf = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DdlBuilder) void {
        self.buf.deinit(self.allocator);
    }

    pub fn toOwnedSlice(self: *DdlBuilder) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }

    pub fn toOwnedSliceZ(self: *DdlBuilder) ![:0]u8 {
        return self.buf.toOwnedSliceSentinel(self.allocator, 0);
    }

    /// Emits a `CREATE TABLE` statement into the builder buffer.
    pub fn addCreateTable(self: *DdlBuilder, table: TableDef) DdlError!void {
        if (table.name.len == 0) return error.EmptyTableName;
        if (table.columns.len == 0) return error.EmptyTableColumns;

        try self.buf.appendSlice(self.allocator, "CREATE ");
        if (table.temp) try self.buf.appendSlice(self.allocator, "TEMP ");
        try self.buf.appendSlice(self.allocator, "TABLE ");
        if (table.if_not_exists) try self.buf.appendSlice(self.allocator, "IF NOT EXISTS ");
        try writeQuotedIdent(&self.buf, self.allocator, table.name);
        try self.buf.appendSlice(self.allocator, " (\n");

        for (table.columns, 0..) |col, i| {
            if (i > 0) try self.buf.appendSlice(self.allocator, ",\n");
            try self.buf.appendSlice(self.allocator, "  ");
            try self.writeColumnDef(col, table.without_rowid);
        }

        for (table.constraints) |constraint| {
            try self.buf.appendSlice(self.allocator, ",\n  ");
            try self.writeTableConstraint(constraint);
        }

        try self.buf.appendSlice(self.allocator, "\n)");
        if (table.strict and table.without_rowid) {
            try self.buf.appendSlice(self.allocator, " STRICT, WITHOUT ROWID;\n");
        } else if (table.strict) {
            try self.buf.appendSlice(self.allocator, " STRICT;\n");
        } else if (table.without_rowid) {
            try self.buf.appendSlice(self.allocator, " WITHOUT ROWID;\n");
        } else {
            try self.buf.appendSlice(self.allocator, ";\n");
        }
    }

    pub fn addAlterTableAddColumn(self: *DdlBuilder, table_name: []const u8, col: ColumnDef) DdlError!void {
        if (table_name.len == 0) return error.EmptyTableName;
        try self.buf.appendSlice(self.allocator, "ALTER TABLE ");
        try writeQuotedIdent(&self.buf, self.allocator, table_name);
        try self.buf.appendSlice(self.allocator, " ADD COLUMN ");
        try self.writeColumnDef(col, false);
        try self.buf.appendSlice(self.allocator, ";\n");
    }

    fn writeColumnDef(self: *DdlBuilder, col: ColumnDef, without_rowid: bool) DdlError!void {
        if (col.name.len == 0) return error.EmptyColumnName;
        if (col.autoincrement) {
            if (!col.primary_key or col.storage_type != .integer) {
                return error.AutoincrementRequiresIntegerPrimaryKey;
            }
            if (without_rowid) {
                return error.WithoutRowidIncompatibleWithAutoincrement;
            }
        }

        try writeQuotedIdent(&self.buf, self.allocator, col.name);
        try self.buf.append(self.allocator, ' ');
        try self.buf.appendSlice(self.allocator, col.storage_type.toSql());

        if (col.generated) |gen| {
            try self.buf.appendSlice(self.allocator, " GENERATED ALWAYS AS (");
            try self.buf.appendSlice(self.allocator, gen.expr);
            try self.buf.appendSlice(self.allocator, ") ");
            try self.buf.appendSlice(self.allocator, gen.storage.toSql());
        }

        if (col.primary_key) {
            try self.buf.appendSlice(self.allocator, " PRIMARY KEY");
            if (col.pk_order) |ord| {
                try self.buf.append(self.allocator, ' ');
                try self.buf.appendSlice(self.allocator, ord.toSql());
            }
            if (col.pk_conflict) |conf| {
                try self.buf.appendSlice(self.allocator, " ON CONFLICT ");
                try self.buf.appendSlice(self.allocator, conf.toSql());
            }
            if (col.autoincrement) {
                try self.buf.appendSlice(self.allocator, " AUTOINCREMENT");
            }
        }

        if (col.not_null and !col.primary_key) {
            try self.buf.appendSlice(self.allocator, " NOT NULL");
        }

        if (col.unique and !col.primary_key) {
            try self.buf.appendSlice(self.allocator, " UNIQUE");
            if (col.unique_conflict) |conf| {
                try self.buf.appendSlice(self.allocator, " ON CONFLICT ");
                try self.buf.appendSlice(self.allocator, conf.toSql());
            }
        }

        if (col.collate) |coll| {
            try self.buf.appendSlice(self.allocator, " COLLATE ");
            try writeQuotedIdent(&self.buf, self.allocator, coll);
        }

        if (col.default_val) |def_val| {
            try self.buf.appendSlice(self.allocator, " DEFAULT ");
            try writeDefaultSpec(&self.buf, self.allocator, def_val);
        }

        if (col.check_expr) |chk| {
            try self.buf.appendSlice(self.allocator, " CHECK (");
            try self.buf.appendSlice(self.allocator, chk);
            try self.buf.append(self.allocator, ')');
        }

        if (col.references) |fk| {
            try self.buf.appendSlice(self.allocator, " REFERENCES ");
            try writeQuotedIdent(&self.buf, self.allocator, fk.table);
            try self.buf.append(self.allocator, '(');
            try writeQuotedIdent(&self.buf, self.allocator, fk.column);
            try self.buf.append(self.allocator, ')');
            if (fk.on_delete) |act| {
                try self.buf.appendSlice(self.allocator, " ON DELETE ");
                try self.buf.appendSlice(self.allocator, act.toSql());
            }
            if (fk.on_update) |act| {
                try self.buf.appendSlice(self.allocator, " ON UPDATE ");
                try self.buf.appendSlice(self.allocator, act.toSql());
            }
            if (fk.deferrable_initially_deferred) {
                try self.buf.appendSlice(self.allocator, " DEFERRABLE INITIALLY DEFERRED");
            }
        }
    }

    fn writeTableConstraint(self: *DdlBuilder, constraint: TableConstraint) DdlError!void {
        switch (constraint) {
            .primary_key => |pk| {
                if (pk.columns.len == 0) return error.EmptyTableColumns;
                if (pk.name) |n| {
                    try self.buf.appendSlice(self.allocator, "CONSTRAINT ");
                    try writeQuotedIdent(&self.buf, self.allocator, n);
                    try self.buf.append(self.allocator, ' ');
                }
                try self.buf.appendSlice(self.allocator, "PRIMARY KEY (");
                try writeIdentList(&self.buf, self.allocator, pk.columns);
                try self.buf.append(self.allocator, ')');
                if (pk.conflict) |conf| {
                    try self.buf.appendSlice(self.allocator, " ON CONFLICT ");
                    try self.buf.appendSlice(self.allocator, conf.toSql());
                }
            },
            .unique => |uq| {
                if (uq.columns.len == 0) return error.EmptyTableColumns;
                if (uq.name) |n| {
                    try self.buf.appendSlice(self.allocator, "CONSTRAINT ");
                    try writeQuotedIdent(&self.buf, self.allocator, n);
                    try self.buf.append(self.allocator, ' ');
                }
                try self.buf.appendSlice(self.allocator, "UNIQUE (");
                try writeIdentList(&self.buf, self.allocator, uq.columns);
                try self.buf.append(self.allocator, ')');
                if (uq.conflict) |conf| {
                    try self.buf.appendSlice(self.allocator, " ON CONFLICT ");
                    try self.buf.appendSlice(self.allocator, conf.toSql());
                }
            },
            .check => |chk| {
                if (chk.name) |n| {
                    try self.buf.appendSlice(self.allocator, "CONSTRAINT ");
                    try writeQuotedIdent(&self.buf, self.allocator, n);
                    try self.buf.append(self.allocator, ' ');
                }
                try self.buf.appendSlice(self.allocator, "CHECK (");
                try self.buf.appendSlice(self.allocator, chk.expr);
                try self.buf.append(self.allocator, ')');
            },
            .foreign_key => |fk| {
                if (fk.from_columns.len == 0 or fk.from_columns.len != fk.target_columns.len) {
                    return error.ForeignKeyColumnCountMismatch;
                }
                if (fk.name) |n| {
                    try self.buf.appendSlice(self.allocator, "CONSTRAINT ");
                    try writeQuotedIdent(&self.buf, self.allocator, n);
                    try self.buf.append(self.allocator, ' ');
                }
                try self.buf.appendSlice(self.allocator, "FOREIGN KEY (");
                try writeIdentList(&self.buf, self.allocator, fk.from_columns);
                try self.buf.appendSlice(self.allocator, ") REFERENCES ");
                try writeQuotedIdent(&self.buf, self.allocator, fk.target_table);
                try self.buf.append(self.allocator, '(');
                try writeIdentList(&self.buf, self.allocator, fk.target_columns);
                try self.buf.append(self.allocator, ')');
                if (fk.on_delete) |act| {
                    try self.buf.appendSlice(self.allocator, " ON DELETE ");
                    try self.buf.appendSlice(self.allocator, act.toSql());
                }
                if (fk.on_update) |act| {
                    try self.buf.appendSlice(self.allocator, " ON UPDATE ");
                    try self.buf.appendSlice(self.allocator, act.toSql());
                }
                if (fk.deferrable_initially_deferred) {
                    try self.buf.appendSlice(self.allocator, " DEFERRABLE INITIALLY DEFERRED");
                }
            },
        }
    }

    /// Emits a `CREATE [UNIQUE] INDEX` statement into the builder buffer.
    pub fn addCreateIndex(self: *DdlBuilder, idx: IndexDef) DdlError!void {
        if (idx.name.len == 0) return error.EmptyIndexName;
        if (idx.table.len == 0) return error.EmptyTableName;
        if (idx.columns.len == 0) return error.EmptyIndexColumns;

        try self.buf.appendSlice(self.allocator, "CREATE ");
        if (idx.unique) try self.buf.appendSlice(self.allocator, "UNIQUE ");
        try self.buf.appendSlice(self.allocator, "INDEX ");
        if (idx.if_not_exists) try self.buf.appendSlice(self.allocator, "IF NOT EXISTS ");
        try writeQuotedIdent(&self.buf, self.allocator, idx.name);
        try self.buf.appendSlice(self.allocator, " ON ");
        try writeQuotedIdent(&self.buf, self.allocator, idx.table);
        try self.buf.appendSlice(self.allocator, " (");

        for (idx.columns, 0..) |col, i| {
            if (col.name_or_expr.len == 0) return error.EmptyColumnName;
            if (i > 0) try self.buf.appendSlice(self.allocator, ", ");
            if (col.is_expr) {
                try self.buf.append(self.allocator, '(');
                try self.buf.appendSlice(self.allocator, col.name_or_expr);
                try self.buf.append(self.allocator, ')');
            } else {
                try writeQuotedIdent(&self.buf, self.allocator, col.name_or_expr);
            }
            if (col.collate) |coll| {
                try self.buf.appendSlice(self.allocator, " COLLATE ");
                try writeQuotedIdent(&self.buf, self.allocator, coll);
            }
            if (col.order) |ord| {
                try self.buf.append(self.allocator, ' ');
                try self.buf.appendSlice(self.allocator, ord.toSql());
            }
        }

        try self.buf.append(self.allocator, ')');
        if (idx.where_expr) |w| {
            if (w.len > 0) {
                try self.buf.appendSlice(self.allocator, " WHERE ");
                try self.buf.appendSlice(self.allocator, w);
            }
        }
        try self.buf.appendSlice(self.allocator, ";\n");
    }

    /// Emits a `CREATE [TEMP] VIEW` statement into the builder buffer.
    pub fn addCreateView(self: *DdlBuilder, view: ViewDef) DdlError!void {
        if (view.name.len == 0) return error.EmptyViewName;
        const select_trimmed = std.mem.trim(u8, view.select_sql, " \t\r\n;");
        if (select_trimmed.len == 0) return error.EmptyViewSelect;

        try self.buf.appendSlice(self.allocator, "CREATE ");
        if (view.temp) try self.buf.appendSlice(self.allocator, "TEMP ");
        try self.buf.appendSlice(self.allocator, "VIEW ");
        if (view.if_not_exists) try self.buf.appendSlice(self.allocator, "IF NOT EXISTS ");
        try writeQuotedIdent(&self.buf, self.allocator, view.name);

        if (view.columns.len > 0) {
            try self.buf.appendSlice(self.allocator, " (");
            try writeIdentList(&self.buf, self.allocator, view.columns);
            try self.buf.append(self.allocator, ')');
        }

        try self.buf.appendSlice(self.allocator, " AS ");
        try self.buf.appendSlice(self.allocator, select_trimmed);
        try self.buf.appendSlice(self.allocator, ";\n");
    }

    /// Emits a `CREATE [TEMP] TRIGGER` statement into the builder buffer.
    pub fn addCreateTrigger(self: *DdlBuilder, trig: TriggerDef) DdlError!void {
        if (trig.name.len == 0) return error.EmptyTriggerName;
        if (trig.table.len == 0) return error.EmptyTableName;
        const body_trimmed = std.mem.trim(u8, trig.body_sql, " \t\r\n;");
        if (body_trimmed.len == 0) return error.EmptyTriggerBody;

        try self.buf.appendSlice(self.allocator, "CREATE ");
        if (trig.temp) try self.buf.appendSlice(self.allocator, "TEMP ");
        try self.buf.appendSlice(self.allocator, "TRIGGER ");
        if (trig.if_not_exists) try self.buf.appendSlice(self.allocator, "IF NOT EXISTS ");
        try writeQuotedIdent(&self.buf, self.allocator, trig.name);
        try self.buf.append(self.allocator, ' ');
        try self.buf.appendSlice(self.allocator, trig.timing.toSql());
        try self.buf.append(self.allocator, ' ');

        switch (trig.event) {
            .insert => try self.buf.appendSlice(self.allocator, "INSERT"),
            .delete => try self.buf.appendSlice(self.allocator, "DELETE"),
            .update => |cols| {
                try self.buf.appendSlice(self.allocator, "UPDATE");
                if (cols.len > 0) {
                    try self.buf.appendSlice(self.allocator, " OF ");
                    try writeIdentList(&self.buf, self.allocator, cols);
                }
            },
        }

        try self.buf.appendSlice(self.allocator, " ON ");
        try writeQuotedIdent(&self.buf, self.allocator, trig.table);
        if (trig.for_each_row) {
            try self.buf.appendSlice(self.allocator, " FOR EACH ROW");
        }
        if (trig.when_expr) |w| {
            if (w.len > 0) {
                try self.buf.appendSlice(self.allocator, " WHEN (");
                try self.buf.appendSlice(self.allocator, w);
                try self.buf.append(self.allocator, ')');
            }
        }
        try self.buf.appendSlice(self.allocator, " BEGIN\n  ");
        try self.buf.appendSlice(self.allocator, body_trimmed);
        try self.buf.appendSlice(self.allocator, ";\nEND;\n");
    }

    pub fn addDropTable(self: *DdlBuilder, table_name: []const u8, if_exists: bool) DdlError!void {
        if (table_name.len == 0) return error.EmptyTableName;
        try self.buf.appendSlice(self.allocator, "DROP TABLE ");
        if (if_exists) try self.buf.appendSlice(self.allocator, "IF EXISTS ");
        try writeQuotedIdent(&self.buf, self.allocator, table_name);
        try self.buf.appendSlice(self.allocator, ";\n");
    }

    pub fn addDropIndex(self: *DdlBuilder, index_name: []const u8, if_exists: bool) DdlError!void {
        if (index_name.len == 0) return error.EmptyIndexName;
        try self.buf.appendSlice(self.allocator, "DROP INDEX ");
        if (if_exists) try self.buf.appendSlice(self.allocator, "IF EXISTS ");
        try writeQuotedIdent(&self.buf, self.allocator, index_name);
        try self.buf.appendSlice(self.allocator, ";\n");
    }

    pub fn addDropView(self: *DdlBuilder, view_name: []const u8, if_exists: bool) DdlError!void {
        if (view_name.len == 0) return error.EmptyViewName;
        try self.buf.appendSlice(self.allocator, "DROP VIEW ");
        if (if_exists) try self.buf.appendSlice(self.allocator, "IF EXISTS ");
        try writeQuotedIdent(&self.buf, self.allocator, view_name);
        try self.buf.appendSlice(self.allocator, ";\n");
    }
};

/// Safely quotes a SQLite identifier (`"name"`, doubling any embedded `"` as `""`, rejecting NUL bytes).
pub fn writeQuotedIdent(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, ident: []const u8) DdlError!void {
    if (ident.len == 0) return error.InvalidIdentifier;
    for (ident) |ch| {
        if (ch == 0) return error.InvalidIdentifier;
    }
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

pub fn writeIdentList(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    idents: []const []const u8,
) DdlError!void {
    for (idents, 0..) |ident, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try writeQuotedIdent(buf, allocator, ident);
    }
}

/// Safely escapes a SQL single-quoted text literal (`'text'`, doubling any `'` as `''`).
pub fn writeSqlStringLiteral(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, text: []const u8) !void {
    try buf.append(allocator, '\'');
    for (text) |ch| {
        if (ch == '\'') {
            try buf.appendSlice(allocator, "''");
        } else {
            try buf.append(allocator, ch);
        }
    }
    try buf.append(allocator, '\'');
}

/// Safely encodes a binary slice as a SQLite hex blob literal (`X'...'`).
pub fn writeSqlBlobLiteral(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, bytes: []const u8) !void {
    const hex_chars = "0123456789ABCDEF";
    try buf.appendSlice(allocator, "X'");
    for (bytes) |b| {
        try buf.append(allocator, hex_chars[b >> 4]);
        try buf.append(allocator, hex_chars[b & 0x0f]);
    }
    try buf.append(allocator, '\'');
}

pub fn writeDefaultSpec(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, def_val: DefaultSpec) DdlError!void {
    switch (def_val) {
        .null_val => try buf.appendSlice(allocator, "NULL"),
        .int64 => |v| {
            var num_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{v}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .float64 => |v| {
            var num_buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{v}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .boolean => |v| try buf.appendSlice(allocator, if (v) "1" else "0"),
        .text => |s| try writeSqlStringLiteral(buf, allocator, s),
        .blob => |b| try writeSqlBlobLiteral(buf, allocator, b),
        .raw_expr => |expr| {
            try buf.append(allocator, '(');
            try buf.appendSlice(allocator, expr);
            try buf.append(allocator, ')');
        },
    }
}
