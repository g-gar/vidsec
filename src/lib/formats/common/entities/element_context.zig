const std = @import("std");
const ByteSource = @import("byte_source.zig").ByteSource;

/// Contextual data passed to in-line validation checks as elements are parsed.
pub const ElementContext = struct {
    offset: u64,
    declared_size: u64,
    header_size: u32,
    depth: u16,
    id_str: []const u8,
    file_size: u64,
    source: ByteSource,
    parent_id_str: ?[]const u8 = null,
};
