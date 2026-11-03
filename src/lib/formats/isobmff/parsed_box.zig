const std = @import("std");
const BoxHeader = @import("box_header.zig").BoxHeader;
const BoxRole = @import("box_role.zig").BoxRole;

/// Flattened representation of a parsed Box within the container tree.
pub const ParsedBox = struct {
    id: u32,
    parent_id: ?u32,
    depth: u16,
    header: BoxHeader,
    is_full_box: bool = false,
    version: u8 = 0,
    flags: u24 = 0,
    role: BoxRole = .unknown,
    child_count: u32 = 0,
};
