const std = @import("std");
const ir = @import("vidsec_ir");
const common = @import("common.zig");
const types = @import("types.zig");
const RegionInput = types.RegionInput;
const LowerContainerOutput = types.LowerContainerOutput;

/// Pure Black Box lowering: transforms EBML elements into universal IR regions and metadata.
pub fn lowerEbmlContainer(
    allocator: std.mem.Allocator,
    file_size: i64,
    true_magic_kind: i64,
    true_magic_name: []const u8,
    elements: []const RegionInput,
) !LowerContainerOutput {
    return common.lowerRegions(
        allocator,
        file_size,
        ir.ContainerFormat.ebml,
        true_magic_kind,
        true_magic_name,
        elements,
    );
}
