const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../lib/mod.zig");
const sqlite = @import("../../extensions/datasources/sqlite_lib/mod.zig");
const EnvInterpolator = @import("../env.zig").EnvInterpolator;

pub const SchemaLoadError = error{
    UnsupportedSchemaVersion,
    EmptyTableColumns,
    InvalidDefaultValue,
    InvalidForeignKeyRef,
    IndexedColumnNotFound,
    CompositeKeyColumnNotFound,
    DuplicateTableNameAcrossDomains,
    ConflictingViewAndColumns,
    InvalidIndexSpec,
    OutOfMemory,
};

/// 1:1 bijection with `ValueTag_ABI` and SQLite `STRICT` column types.
pub const ColumnType = enum {
    int64,
    float64,
    bool,
    text,
    blob,
    any,

    pub fn toStorageType(self: ColumnType) sqlite.StorageType {
        return switch (self) {
            .int64, .bool => .integer,
            .float64 => .real,
            .text => .text,
            .blob => .blob,
            .any => .any,
        };
    }
};

pub const DefaultValue = union(enum) {
    null_val,
    int64: i64,
    float64: f64,
    boolean: bool,
    text: []const u8,
    raw_expr: []const u8,

    pub fn toSqliteDefault(self: DefaultValue) sqlite.DefaultSpec {
        return switch (self) {
            .null_val => .null_val,
            .int64 => |v| .{ .int64 = v },
            .float64 => |v| .{ .float64 = v },
            .boolean => |v| .{ .boolean = v },
            .text => |v| .{ .text = v },
            .raw_expr => |v| .{ .raw_expr = v },
        };
    }
};

/// Custom scalar type for `ref: <table_name>.<column_name>`.
pub const ForeignKeyRef = struct {
    table: []const u8,
    column: []const u8,

    pub fn yamlParseScalar(
        arena: Allocator,
        scalar: yaml.Scalar,
        _: yaml.SourceLoc,
    ) SchemaLoadError!ForeignKeyRef {
        const s = scalar.value;
        const dot_idx = std.mem.indexOfScalar(u8, s, '.') orelse return error.InvalidForeignKeyRef;
        const ref_tbl = s[0..dot_idx];
        const ref_col = s[dot_idx + 1 ..];
        if (ref_tbl.len == 0 or ref_col.len == 0 or std.mem.indexOfScalar(u8, ref_col, '.') != null) {
            return error.InvalidForeignKeyRef;
        }
        return ForeignKeyRef{
            .table = try arena.dupe(u8, ref_tbl),
            .column = try arena.dupe(u8, ref_col),
        };
    }
};

/// Column definition inside a table (`columns.<col_name>`).
/// Supports simple definitions (`{ type: int64, pk: true }`) as well as full SQLite DDL features
/// (`unique`, `autoincrement`, `check`, `collate`, `generated_as`, `on_delete`, `on_update`, `default_expr`).
pub const ColumnSpec = struct {
    col_type: ColumnType,
    pk: bool = false,
    autoincrement: bool = false,
    nullable: bool = false,
    unique: bool = false,
    default_raw: ?[]const u8 = null,
    default_expr: ?[]const u8 = null,
    check: ?[]const u8 = null,
    collate: ?[]const u8 = null,
    generated_as: ?[]const u8 = null,
    stored: bool = false,
    ref: ?ForeignKeyRef = null,
    on_delete: ?sqlite.ForeignKeyAction = null,
    on_update: ?sqlite.ForeignKeyAction = null,

    pub const yaml_fields = .{
        .col_type = "type",
        .default_raw = "default",
    };

    pub fn parsedDefault(self: ColumnSpec) SchemaLoadError!?DefaultValue {
        if (self.default_expr) |expr| {
            if (expr.len == 0) return error.InvalidDefaultValue;
            return .{ .raw_expr = expr };
        }
        const raw = self.default_raw orelse return null;
        if (std.mem.eql(u8, raw, "null") and self.nullable) {
            return .null_val;
        }
        return switch (self.col_type) {
            .int64 => .{ .int64 = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidDefaultValue },
            .float64 => .{ .float64 = std.fmt.parseFloat(f64, raw) catch return error.InvalidDefaultValue },
            .bool => blk: {
                if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) break :blk .{ .boolean = true };
                if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0")) break :blk .{ .boolean = false };
                return error.InvalidDefaultValue;
            },
            .text, .any => .{ .text = raw },
            .blob => error.InvalidDefaultValue,
        };
    }

    pub fn yamlValidate(self: *const ColumnSpec, _: Allocator) SchemaLoadError!void {
        if (self.default_raw != null and self.default_expr != null) {
            return error.InvalidDefaultValue;
        }
        _ = try self.parsedDefault();
    }
};

/// Flexible index specification in `indexes:`:
/// - Can be a simple column name string: `- role`
/// - Or a rich object: `- { name: idx_custom, columns: [role, tag_name], unique: true, where: "role != 'unknown'" }`
pub const IndexSpec = struct {
    name: ?[]const u8 = null,
    columns: []const []const u8 = &.{},
    expressions: []const []const u8 = &.{},
    unique: bool = false,
    where: ?[]const u8 = null,
    order: ?sqlite.SortOrder = null,

    const RichIndexHelper = struct {
        name: ?[]const u8 = null,
        columns: []const []const u8 = &.{},
        expressions: []const []const u8 = &.{},
        unique: bool = false,
        where: ?[]const u8 = null,
        order: ?sqlite.SortOrder = null,
    };

    pub fn yamlParse(
        arena: Allocator,
        node: yaml.Node,
        options: yaml.ParseOptions,
    ) anyerror!IndexSpec {
        if (node.asScalar()) |col_name| {
            if (col_name.len == 0) return error.InvalidIndexSpec;
            const cols = try arena.alloc([]const u8, 1);
            cols[0] = try arena.dupe(u8, col_name);
            return IndexSpec{
                .columns = cols,
            };
        }
        const rich = try yaml.parseFromNode(RichIndexHelper, arena, node, options);
        if (rich.columns.len == 0 and rich.expressions.len == 0) {
            return error.InvalidIndexSpec;
        }
        return IndexSpec{
            .name = rich.name,
            .columns = rich.columns,
            .expressions = rich.expressions,
            .unique = rich.unique,
            .where = rich.where,
            .order = rich.order,
        };
    }
};

/// Table (or view) definition inside a domain (`schemas.<domain>.<table_name>`).
pub const TableSchema = struct {
    columns: yaml.Map(ColumnSpec) = .{},
    indexes: []const IndexSpec = &.{},
    primary_key: []const []const u8 = &.{},
    unique_keys: []const []const []const u8 = &.{},
    checks: []const []const u8 = &.{},
    strict: bool = true,
    without_rowid: bool = false,
    temp: bool = false,
    /// Optional `SELECT ...` query if this entry defines a read-only SQL `VIEW`.
    view_as: ?[]const u8 = null,

    pub fn isView(self: *const TableSchema) bool {
        return self.view_as != null;
    }

    pub fn findColumn(self: *const TableSchema, col_name: []const u8) ?ColumnSpec {
        return self.columns.get(col_name);
    }

    pub fn yamlValidate(self: *const TableSchema, _: Allocator) SchemaLoadError!void {
        if (self.view_as) |v_sql| {
            if (std.mem.trim(u8, v_sql, " \t\r\n;").len == 0) return error.EmptyTableColumns;
            return;
        }

        if (self.columns.count() == 0) return error.EmptyTableColumns;

        for (self.primary_key) |pk_col| {
            if (!self.columns.contains(pk_col)) return error.CompositeKeyColumnNotFound;
        }

        for (self.unique_keys) |uk_group| {
            if (uk_group.len == 0) return error.CompositeKeyColumnNotFound;
            for (uk_group) |uk_col| {
                if (!self.columns.contains(uk_col)) return error.CompositeKeyColumnNotFound;
            }
        }

        for (self.indexes) |idx_spec| {
            for (idx_spec.columns) |idx_col| {
                if (!self.columns.contains(idx_col)) {
                    return error.IndexedColumnNotFound;
                }
            }
        }
    }
};

pub const DomainSchema = yaml.Map(TableSchema);

/// Domain schema catalog decoded directly from `schemas.yaml` via `lib/yaml`.
pub const SchemaCatalog = struct {
    version: u32,
    schemas: yaml.Map(DomainSchema),

    /// Parses a `schemas.yaml` string into a `SchemaCatalog` allocated in `arena`.
    pub fn parseYaml(
        arena: Allocator,
        yaml_src: []const u8,
        env: ?*const EnvInterpolator,
    ) anyerror!SchemaCatalog {
        const opts = yaml.ParseOptions{
            .scalar_hook = if (env) |e| e.scalarHook() else null,
        };
        return yaml.parse(SchemaCatalog, arena, yaml_src, opts);
    }

    pub fn yamlValidate(self: *const SchemaCatalog, arena: Allocator) SchemaLoadError!void {
        if (self.version != 2) return error.UnsupportedSchemaVersion;

        var seen_tables: std.StringHashMapUnmanaged(TableSchema) = .empty;
        for (self.schemas.entries) |dom_entry| {
            for (dom_entry.value.entries) |tbl_entry| {
                if (seen_tables.contains(tbl_entry.key)) {
                    return error.DuplicateTableNameAcrossDomains;
                }
                try seen_tables.put(arena, tbl_entry.key, tbl_entry.value);
            }
        }

        // Cross-check all foreign key references across the catalog
        for (self.schemas.entries) |dom_entry| {
            for (dom_entry.value.entries) |tbl_entry| {
                for (tbl_entry.value.columns.entries) |col_entry| {
                    if (col_entry.value.ref) |fk| {
                        const target_tbl = seen_tables.get(fk.table) orelse return error.InvalidForeignKeyRef;
                        if (!target_tbl.columns.contains(fk.column)) {
                            return error.InvalidForeignKeyRef;
                        }
                    }
                }
            }
        }
    }

    pub fn getDomain(self: *const SchemaCatalog, domain_name: []const u8) ?DomainSchema {
        return self.schemas.get(domain_name);
    }

    pub fn getTable(self: *const SchemaCatalog, table_name: []const u8) ?TableSchema {
        for (self.schemas.entries) |dom_entry| {
            if (dom_entry.value.get(table_name)) |tbl| return tbl;
        }
        return null;
    }
};
