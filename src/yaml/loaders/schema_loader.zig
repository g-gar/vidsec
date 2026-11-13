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

test "SchemaCatalog: parse actual configs/schemas.yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = try std.fs.cwd().openFile("configs/schemas.yaml", .{});
    defer file.close();
    const yaml_bytes = try file.readToEndAlloc(alloc, 1024 * 1024);

    const catalog = try SchemaCatalog.parseYaml(alloc, yaml_bytes, null);
    try catalog.yamlValidate(alloc);

    try std.testing.expect(catalog.getTable("enum_container_format") != null);
    try std.testing.expect(catalog.getTable("enum_severity") != null);
    try std.testing.expect(catalog.getTable("enum_verdict") != null);
    try std.testing.expect(catalog.getTable("enum_region_role") != null);
}
