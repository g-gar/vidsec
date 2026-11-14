const std = @import("std");
const media_ir = @import("media_ir");

/// Lowers parsed EBML elements into universal `media_ir` regions and metadata.
pub fn lowerContainer(
    allocator: std.mem.Allocator,
    file_size: i64,
    true_magic_kind: i64,
    true_magic_name: []const u8,
    elements: []const media_ir.RegionInput,
) !media_ir.LowerContainerOutput {
    return media_ir.lowerRegions(
        allocator,
        file_size,
        .ebml,
        true_magic_kind,
        true_magic_name,
        elements,
    );
}

