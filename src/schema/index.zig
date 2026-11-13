const std = @import("std");
const yaml = @import("../yaml/lib/mod.zig");
const SortOrder = @import("types.zig").SortOrder;

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
        arena: std.mem.Allocator,
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
