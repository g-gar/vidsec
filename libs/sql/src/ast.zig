/// Pure, engine-agnostic SQL AST (`SelectQuery`, `InsertQuery`, `UpdateQuery`, `DeleteQuery`, `Expr`).
/// Zero dependencies on Flowdata or any specific database driver (ARCH-009D).

pub const SqlValue = union(enum) {
    null_val,
    int64: i64,
    float64: f64,
    boolean: bool,
    text: []const u8,
    blob: []const u8,
};

pub const CmpOp = enum {
    eq,
    ne,
    lt,
    lte,
    gt,
    gte,
};

pub const SortOrder = enum {
    asc,
    desc,
};

pub const OrderBy = struct {
    column: []const u8,
    order: SortOrder = .asc,
};

pub const Expr = union(enum) {
    @"and": BinaryLogical,
    @"or": BinaryLogical,
    not: *const Expr,
    cmp: Comparison,
    is_null: []const u8,
    is_not_null: []const u8,
    in_list: InList,
    literal: bool,

    pub const BinaryLogical = struct {
        left: *const Expr,
        right: *const Expr,
    };

    pub const Comparison = struct {
        column: []const u8,
        op: CmpOp,
        value: SqlValue,
    };

    pub const InList = struct {
        column: []const u8,
        values: []const SqlValue,
    };
};

pub const SelectQuery = struct {
    table: []const u8,
    /// Empty slice means `SELECT *`.
    columns: []const []const u8 = &.{},
    where: ?*const Expr = null,
    order_by: []const OrderBy = &.{},
    limit: ?usize = null,
    offset: ?usize = null,
};

pub const OnConflict = struct {
    conflict_columns: []const []const u8,
    action: union(enum) {
        do_nothing,
        /// Columns to update from excluded/incoming values.
        do_update: []const []const u8,
    },
};

pub const InsertQuery = struct {
    table: []const u8,
    columns: []const []const u8,
    values: []const SqlValue,
    or_ignore: bool = false,
    on_conflict: ?OnConflict = null,
};

pub const Assignment = struct {
    column: []const u8,
    value: SqlValue,
};

pub const UpdateQuery = struct {
    table: []const u8,
    assignments: []const Assignment,
    where: ?*const Expr = null,
};

pub const DeleteQuery = struct {
    table: []const u8,
    where: ?*const Expr = null,
};

pub const Query = union(enum) {
    select: SelectQuery,
    insert: InsertQuery,
    update: UpdateQuery,
    delete: DeleteQuery,
};

