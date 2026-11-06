const std = @import("std");
const ElementHeader = @import("element_header.zig").ElementHeader;
const ElementRole = @import("element_role.zig").ElementRole;

/// A fully indexed EBML element in the parsed container hierarchy.
pub const ParsedElement = struct {
    id: u32,
    parent_id: ?u32,
    depth: u16,
    header: ElementHeader,
    role: ElementRole,
    child_count: u32 = 0,
};
