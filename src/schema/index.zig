const SortOrder = @import("types.zig").SortOrder;

pub const IndexSpec = struct {
    name: ?[]const u8 = null,
    columns: []const []const u8 = &.{},
    expressions: []const []const u8 = &.{},
    unique: bool = false,
    where: ?[]const u8 = null,
    order: ?SortOrder = null,
};
