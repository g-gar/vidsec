const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../../../lib/yaml/mod.zig");

pub const InputSpecError = error{
    MissingStreamFrom,
    EmptyInputChannel,
    ConflictingQueryAndTable,
    MissingInputMapOrQuery,
    InvalidInputMapEntry,
    OutOfMemory,
};

/// Custom scalar type for `from: file | <artifact_id>`.
pub const StreamSource = union(enum) {
    file,
    artifact: []const u8,

    pub fn yamlParseScalar(
        arena: Allocator,
        scalar: yaml.Scalar,
        _: yaml.SourceLoc,
    ) InputSpecError!StreamSource {
        if (scalar.value.len == 0) return error.MissingStreamFrom;
        if (std.mem.eql(u8, scalar.value, "file")) return .file;
        return .{ .artifact = try arena.dupe(u8, scalar.value) };
    }
};

/// Generic specification for any named input channel under `input.<channel_name>:`.
/// Supports:
/// - Pure byte streams (`{ from: file }` or `{ from: sanitized_video }`)
/// - Declarative table projections (`{ [from: ...], table: ..., [filter: ...], [order_by: ...], [limit: ...], map: { ... } }`)
/// - Arbitrary SQL queries (`{ [from: ...], query: "SELECT ..." }`)
pub const InputChannelSpec = struct {
    from: ?StreamSource = null,
    table: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    group_by: []const []const u8 = &.{},
    having: ?[]const u8 = null,
    order_by: ?[]const u8 = null,
    limit: ?u64 = null,
    offset: ?u64 = null,
    distinct: bool = false,
    map: ?yaml.Map([]const u8) = null,
    query: ?[]const u8 = null,

    pub fn yamlValidate(self: *const InputChannelSpec, _: Allocator) InputSpecError!void {
        if (self.from == null and self.table == null and self.query == null) {
            return error.EmptyInputChannel;
        }
        if (self.table != null and self.query != null) {
            return error.ConflictingQueryAndTable;
        }
        if (self.table) |tbl| {
            if (tbl.len == 0) return error.EmptyInputChannel;
            if (self.map) |m| {
                if (m.count() == 0) return error.MissingInputMapOrQuery;
                for (m.entries) |entry| {
                    if (entry.key.len == 0 or entry.value.len == 0) {
                        return error.InvalidInputMapEntry;
                    }
                }
            }
        }
        if (self.query) |q| {
            if (q.len == 0) return error.MissingInputMapOrQuery;
        }
    }
};

/// Map of `<channel_name> -> InputChannelSpec` decoded directly by `lib/yaml`.
pub const InputSpec = yaml.Map(InputChannelSpec);
