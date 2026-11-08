const std = @import("std");
const ir = @import("vidsec_ir");
const common = @import("common.zig");
const types = @import("types.zig");
const RegionInput = types.RegionInput;
const LowerContainerOutput = types.LowerContainerOutput;

/// Pure Black Box lowering: transforms RIFF chunks into universal IR regions and metadata.
pub fn lowerRiffContainer(
    allocator: std.mem.Allocator,
    file_size: i64,
    true_magic_kind: i64,
    true_magic_name: []const u8,
    chunks: []const RegionInput,
) !LowerContainerOutput {
    return common.lowerRegions(
        allocator,
        file_size,
        ir.ContainerFormat.riff,
        true_magic_kind,
        true_magic_name,
        chunks,
    );
}
