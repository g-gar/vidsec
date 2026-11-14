const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../lib/mod.zig");
const EnvInterpolator = @import("../env.zig").EnvInterpolator;
const schema = @import("../../schema/mod.zig");

pub const SchemaLoadError = schema.SchemaError;
pub const ColumnType = schema.ColumnType;
pub const DefaultValue = schema.DefaultValue;
pub const SortOrder = schema.SortOrder;
pub const ForeignKeyAction = schema.ForeignKeyAction;
pub const ForeignKeyRef = schema.ForeignKeyRef;
pub const ColumnSpec = schema.ColumnSpec;
pub const IndexSpec = schema.IndexSpec;
pub const SeedRow = schema.SeedRow;
pub const TableSchema = schema.TableSchema;
pub const DomainSchema = schema.DomainSchema;
pub const SchemaCatalog = schema.SchemaCatalog;

// ── YAML-specific intermediate structs (keeps `src/schema/` 100% YAML-free) ──

const YamlForeignKeyRef = struct {
    table: []const u8,
    column: []const u8,

    pub fn yamlParseScalar(
        arena: Allocator,
        scalar: yaml.Scalar,
        _: yaml.SourceLoc,
    ) !YamlForeignKeyRef {
        const s = scalar.value;
        const dot_idx = std.mem.indexOfScalar(u8, s, '.') orelse return error.InvalidForeignKeyRef;
        const ref_tbl = s[0..dot_idx];
        const ref_col = s[dot_idx + 1 ..];
        if (ref_tbl.len == 0 or ref_col.len == 0 or std.mem.indexOfScalar(u8, ref_col, '.') != null) {
            return error.InvalidForeignKeyRef;
        }
        return .{
            .table = try arena.dupe(u8, ref_tbl),
            .column = try arena.dupe(u8, ref_col),
        };
    }
};

const YamlColumnSpec = struct {
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
    ref: ?YamlForeignKeyRef = null,
    on_delete: ?ForeignKeyAction = null,
    on_update: ?ForeignKeyAction = null,

    pub const yaml_fields = .{
        .col_type = "type",
        .default_raw = "default",
    };

    fn toCore(self: YamlColumnSpec) ColumnSpec {
        return .{
            .col_type = self.col_type,
            .pk = self.pk,
            .autoincrement = self.autoincrement,
            .nullable = self.nullable,
            .unique = self.unique,
            .default_raw = self.default_raw,
            .default_expr = self.default_expr,
            .check = self.check,
            .collate = self.collate,
            .generated_as = self.generated_as,
            .stored = self.stored,
            .ref = if (self.ref) |r| .{ .table = r.table, .column = r.column } else null,
            .on_delete = self.on_delete,
            .on_update = self.on_update,
        };
    }
};

const YamlIndexSpec = struct {
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
    ) anyerror!YamlIndexSpec {
        if (node.asScalar()) |col_name| {
            if (col_name.len == 0) return error.InvalidIndexSpec;
            const cols = try arena.alloc([]const u8, 1);
            cols[0] = try arena.dupe(u8, col_name);
            return .{ .columns = cols };
        }
        const rich = try yaml.parseFromNode(RichIndexHelper, arena, node, options);
        if (rich.columns.len == 0 and rich.expressions.len == 0) {
            return error.InvalidIndexSpec;
        }
        return .{
            .name = rich.name,
            .columns = rich.columns,
            .expressions = rich.expressions,
            .unique = rich.unique,
            .where = rich.where,
            .order = rich.order,
        };
    }

    fn toCore(self: YamlIndexSpec) IndexSpec {
        return .{
            .name = self.name,
            .columns = self.columns,
            .expressions = self.expressions,
            .unique = self.unique,
            .where = self.where,
            .order = self.order,
        };
    }
};

const YamlSeedRow = yaml.Map(yaml.Scalar);

const YamlTableSchema = struct {
    columns: yaml.Map(YamlColumnSpec) = .{},
    indexes: []const YamlIndexSpec = &.{},
    primary_key: []const []const u8 = &.{},
    unique_keys: []const []const []const u8 = &.{},
    checks: []const []const u8 = &.{},
    strict: bool = true,
    without_rowid: bool = false,
    temp: bool = false,
    seeds: []const YamlSeedRow = &.{},

    fn toCore(self: YamlTableSchema, arena: Allocator) !TableSchema {
        const cols = try arena.alloc(schema.types.NamedMap(ColumnSpec).Entry, self.columns.entries.len);
        for (self.columns.entries, 0..) |e, i| {
            cols[i] = .{ .key = e.key, .value = e.value.toCore() };
        }

        const idxs = try arena.alloc(IndexSpec, self.indexes.len);
        for (self.indexes, 0..) |idx, i| {
            idxs[i] = idx.toCore();
        }

        const seeds = try arena.alloc(SeedRow, self.seeds.len);
        for (self.seeds, 0..) |yrow, i| {
            const entries = try arena.alloc(SeedRow.Entry, yrow.entries.len);
            for (yrow.entries, 0..) |ye, j| {
                entries[j] = .{
                    .key = ye.key,
                    .value = .{
                        .value = ye.value.value,
                        .quote_style = if (ye.value.quote_style == .plain) .plain else .quoted,
                    },
                };
            }
            seeds[i] = .{ .entries = entries };
        }

        return .{
            .columns = .{ .entries = cols },
            .indexes = idxs,
            .primary_key = self.primary_key,
            .unique_keys = self.unique_keys,
            .checks = self.checks,
            .strict = self.strict,
            .without_rowid = self.without_rowid,
            .temp = self.temp,
            .seeds = seeds,
        };
    }
};

const YamlSchemaCatalog = struct {
    version: u32,
    schemas: yaml.Map(yaml.Map(YamlTableSchema)),

    fn toCore(self: YamlSchemaCatalog, arena: Allocator) !SchemaCatalog {
        const doms = try arena.alloc(schema.types.NamedMap(DomainSchema).Entry, self.schemas.entries.len);
        for (self.schemas.entries, 0..) |dom_entry, i| {
            const tbls = try arena.alloc(DomainSchema.Entry, dom_entry.value.entries.len);
            for (dom_entry.value.entries, 0..) |tbl_entry, j| {
                tbls[j] = .{
                    .key = tbl_entry.key,
                    .value = try tbl_entry.value.toCore(arena),
                };
            }
            doms[i] = .{
                .key = dom_entry.key,
                .value = .{ .entries = tbls },
            };
        }
        return .{
            .version = self.version,
            .schemas = .{ .entries = doms },
        };
    }
};

/// Decodes `schemas.yaml` into a pure, format-agnostic `SchemaCatalog` and validates it.
pub fn parseYaml(
    arena: Allocator,
    yaml_src: []const u8,
    env: ?*const EnvInterpolator,
) anyerror!SchemaCatalog {
    const opts = yaml.ParseOptions{
        .scalar_hook = if (env) |e| e.scalarHook() else null,
    };
    const raw = try yaml.parse(YamlSchemaCatalog, arena, yaml_src, opts);
    const catalog = try raw.toCore(arena);
    try catalog.validate(arena);
    return catalog;
}

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

    const catalog = try parseYaml(alloc, yaml_text, null);

    const tbl = catalog.getTable("enum_test") orelse return error.TestExpectedTable;
    try std.testing.expectEqual(@as(usize, 2), tbl.seeds.len);

    const seed0 = tbl.seeds[0];
    try std.testing.expectEqualStrings("0", seed0.get("id").?.value);
    try std.testing.expectEqualStrings("unknown", seed0.get("code").?.value);
    try std.testing.expectEqualStrings("Unknown's value", seed0.get("descr").?.value);
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

    try std.testing.expectError(error.SeedColumnNotFound, parseYaml(alloc, yaml_text, null));
}

test "SchemaCatalog: parse actual configs/schemas.yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = try std.fs.cwd().openFile("configs/schemas.yaml", .{});
    defer file.close();
    const yaml_bytes = try file.readToEndAlloc(alloc, 1024 * 1024);

    const catalog = try parseYaml(alloc, yaml_bytes, null);
    try std.testing.expectEqual(@as(u32, 2), catalog.version);
}
