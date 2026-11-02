const std = @import("std");
const abi = @import("vidsec_abi");

pub const types = @import("types.zig");
pub const container = @import("container.zig");
pub const media = @import("media.zig");

pub const runLowerContainer = container.runLowerContainer;
pub const runLowerMedia = media.runLowerMedia;

pub const LOWER_CONTAINER_OUTPUT_FIELDS = [_][*:0]const u8{
    "region_id",
    "parent_region_id",
    "tag_name",
    "role",
    "header_offset",
    "payload_offset",
    "effective_end_offset",
    "is_truncated_or_overflow",
};

pub const LOWER_MEDIA_OUTPUT_FIELDS = [_][*:0]const u8{
    "config_id",
    "track_id",
    "codec_tag",
    "container_width",
    "container_height",
    "bitstream_width",
    "bitstream_height",
    "is_mismatch",
};

pub const tasks = [_]abi.TaskDescriptor_ABI{
    abi.defineTask(.{
        .name = "lower_container",
        .description = "Stage 2 IR Lowering: Normalizes format-specific container structures (ISOBMFF, EBML, RIFF) into universal container_metadata and ir_regions",
        .output_fields = &LOWER_CONTAINER_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runLowerContainer,
    }),
    abi.defineTask(.{
        .name = "lower_media",
        .description = "Stage 2 IR Lowering: Normalizes format-specific track and codec tables into universal ir_codec_configs and ir_sample_extents",
        .output_fields = &LOWER_MEDIA_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runLowerMedia,
    }),
};

pub const manifest: abi.ModuleManifest_ABI = abi.defineManifest(
    "ir",
    .{ .major = 2, .minor = 0, .patch = 0 },
    &tasks,
);

// Exports the `vidsec_module_manifest` C-ABI symbol when compiled as a standalone `.so` plugin (`libir.so`)
comptime {
    if (@import("root") == @This()) {
        @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
    }
}
