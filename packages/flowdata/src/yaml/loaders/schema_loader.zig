const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../lib/mod.zig");
const EnvInterpolator = @import("../env.zig").EnvInterpolator;

pub const SchemaLoadError = error{
    UnsupportedSchemaVersion,
    EmptyTableColumns,
    InvalidDefaultValue,
    InvalidForeignKeyRef,
    IndexedColumnNotFound,
    CompositeKeyColumnNotFound,
    DuplicateTableNameAcrossDomains,
    InvalidIndexSpec,
    SeedColumnNotFound,
    OutOfMemory,
};

/// 1:1 bijection with `ValueTag_ABI` and standard column types.
pub const ColumnType = enum {
    int64,
    float64,
    bool,
    text,
    blob,
    any,
};

pub const DefaultValue = union(enum) {
    null_val,
    int64: i64,
    float64: f64,
    boolean: bool,
    text: []const u8,
    raw_expr: []const u8,
};

pub const SortOrder = enum {
    asc,
    desc,
};

pub const ForeignKeyAction = enum {
    no_action,
    restrict,
    set_null,
    set_default,
    cascade,
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
    on_delete: ?ForeignKeyAction = null,
    on_update: ?ForeignKeyAction = null,

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
    order: ?SortOrder = null,

    const RichIndexHelper = struct {
        name: ?[]const u8 = null,
        columns: []const []const u8 = &.{},
        expressions: []const []const u8 = &.{},
        unique: bool = false,
        where: ?[]const u8 = null,
        order: ?SortOrder = null,
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

/// Row entry in a table's declarative `seeds:` block.
pub const SeedRow = yaml.Map(yaml.Scalar);

/// Table definition inside a domain (`schemas.<domain>.<table_name>`).
pub const TableSchema = struct {
    columns: yaml.Map(ColumnSpec) = .{},
    indexes: []const IndexSpec = &.{},
    primary_key: []const []const u8 = &.{},
    unique_keys: []const []const []const u8 = &.{},
    checks: []const []const u8 = &.{},
    strict: bool = true,
    without_rowid: bool = false,
    temp: bool = false,
    /// Optional declarative initial seed rows for lookup and enum tables.
    seeds: []const SeedRow = &.{},

    pub fn findColumn(self: *const TableSchema, col_name: []const u8) ?ColumnSpec {
        return self.columns.get(col_name);
    }

    pub fn yamlValidate(self: *const TableSchema, _: Allocator) SchemaLoadError!void {
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

        for (self.seeds) |seed_row| {
            for (seed_row.entries) |entry| {
                if (!self.columns.contains(entry.key)) {
                    return error.SeedColumnNotFound;
                }
            }
        }
    }

    /// Emits `INSERT OR IGNORE INTO <table_name> (<cols...>) VALUES (<vals...>);`
    /// statements for all seed rows defined in this table schema.
    pub fn renderSeedInsertSql(
        self: *const TableSchema,
        allocator: Allocator,
        table_name: []const u8,
    ) !?[]const u8 {
        if (self.seeds.len == 0) return null;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        for (self.seeds) |seed_row| {
            if (seed_row.entries.len == 0) continue;

            try buf.appendSlice(allocator, "INSERT OR IGNORE INTO ");
            try buf.appendSlice(allocator, table_name);
            try buf.appendSlice(allocator, " (");

            for (seed_row.entries, 0..) |entry, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, entry.key);
            }
            try buf.appendSlice(allocator, ") VALUES (");

            for (seed_row.entries, 0..) |entry, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                const col_spec = self.columns.get(entry.key);
                const col_type = if (col_spec) |c| c.col_type else ColumnType.text;

                const raw_val = entry.value.value;
                if (std.mem.eql(u8, raw_val, "null") and entry.value.quote_style == .plain) {
                    try buf.appendSlice(allocator, "NULL");
                } else switch (col_type) {
                    .int64, .float64 => {
                        try buf.appendSlice(allocator, raw_val);
                    },
                    .bool => {
                        if (std.mem.eql(u8, raw_val, "true") or std.mem.eql(u8, raw_val, "1")) {
                            try buf.appendSlice(allocator, "1");
                        } else {
                            try buf.appendSlice(allocator, "0");
                        }
                    },
                    .text, .blob, .any => {
                        try buf.append(allocator, '\'');
                        for (raw_val) |ch| {
                            if (ch == '\'') {
                                try buf.appendSlice(allocator, "''");
                            } else {
                                try buf.append(allocator, ch);
                            }
                        }
                        try buf.append(allocator, '\'');
                    },
                }
            }
            try buf.appendSlice(allocator, ");\n");
        }

        if (buf.items.len == 0) {
            buf.deinit(allocator);
            return null;
        }

        return try buf.toOwnedSlice(allocator);
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

    /// Emits all seed SQL statements for all tables across all domains in the catalog.
    pub fn renderAllSeedsSql(self: *const SchemaCatalog, allocator: Allocator) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        for (self.schemas.entries) |dom_entry| {
            for (dom_entry.value.entries) |tbl_entry| {
                if (try tbl_entry.value.renderSeedInsertSql(allocator, tbl_entry.key)) |sql| {
                    defer allocator.free(sql);
                    try buf.appendSlice(allocator, sql);
                }
            }
        }

        return try buf.toOwnedSlice(allocator);
    }
};

test "SchemaCatalog: parse and validate declarative seeds" {
    const yaml_text =
        \\version: 2
        \\schemas:
        \\  catalog:
        \\    enum_test:
        \\      columns:
        \\        id:    { type: int64, pk: true }
        \\        code:  { type: text, unique: true }
        \\        descr: { type: text }
        \\        flag:  { type: bool }
        \\      seeds:
        \\        - { id: 0, code: unknown, descr: "Unknown's value", flag: true }
        \\        - { id: 1, code: regular, descr: "Normal", flag: false }
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const catalog = try SchemaCatalog.parseYaml(alloc, yaml_text, null);
    try catalog.yamlValidate(alloc);

    const tbl = catalog.getTable("enum_test") orelse return error.TestExpectedTable;
    try std.testing.expectEqual(@as(usize, 2), tbl.seeds.len);

    const seed0 = tbl.seeds[0];
    try std.testing.expectEqualStrings("0", seed0.get("id").?.value);
    try std.testing.expectEqualStrings("unknown", seed0.get("code").?.value);
    try std.testing.expectEqualStrings("Unknown's value", seed0.get("descr").?.value);

    // Render SQL
    const sql = (try tbl.renderSeedInsertSql(alloc, "enum_test")) orelse return error.TestExpectedSql;
    defer alloc.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT OR IGNORE INTO enum_test (id, code, descr, flag) VALUES (0, 'unknown', 'Unknown''s value', 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT OR IGNORE INTO enum_test (id, code, descr, flag) VALUES (1, 'regular', 'Normal', 0);") != null);
}

test "SchemaCatalog: seeds with non-existent column returns SeedColumnNotFound" {
    const yaml_text =
        \\version: 2
        \\schemas:
        \\  catalog:
        \\    enum_test:
        \\      columns:
        \\        id: { type: int64, pk: true }
        \\      seeds:
        \\        - { id: 0, nonexistent: 123 }
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const catalog = try SchemaCatalog.parseYaml(alloc, yaml_text, null);
    const tbl = catalog.getTable("enum_test").?;
    try std.testing.expectError(error.SeedColumnNotFound, tbl.yamlValidate(alloc));
}

test "SchemaCatalog: parse actual configs/schemas.yaml and render seeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = try std.fs.cwd().openFile("configs/schemas.yaml", .{});
    defer file.close();
    const yaml_bytes = try file.readToEndAlloc(alloc, 1024 * 1024);

    const catalog = try SchemaCatalog.parseYaml(alloc, yaml_bytes, null);
    try catalog.yamlValidate(alloc);

    const all_seeds_sql = try catalog.renderAllSeedsSql(alloc);
    defer alloc.free(all_seeds_sql);

    try std.testing.expect(std.mem.indexOf(u8, all_seeds_sql, "enum_container_format") != null);
    try std.testing.expect(std.mem.indexOf(u8, all_seeds_sql, "enum_severity") != null);
    try std.testing.expect(std.mem.indexOf(u8, all_seeds_sql, "enum_verdict") != null);
    try std.testing.expect(std.mem.indexOf(u8, all_seeds_sql, "enum_region_role") != null);
}
