const std = @import("std");
const ebml_constants = @import("ebml_constants.zig");

/// High-level role of an EBML element in container analysis.
pub const ElementRole = enum {
    header,
    metadata,
    track_info,
    cluster_index,
    media_data,
    padding,
    unknown,

    pub fn asText(self: ElementRole) []const u8 {
        return switch (self) {
            .header => "header",
            .metadata => "metadata",
            .track_info => "track_info",
            .cluster_index => "cluster_index",
            .media_data => "media_data",
            .padding => "padding",
            .unknown => "unknown",
        };
    }

    pub fn fromId(id: u32) ElementRole {
        return switch (id) {
            ebml_constants.ID_EBML_HEADER => .header,
            ebml_constants.ID_SEGMENT,
            ebml_constants.ID_INFO,
            ebml_constants.ID_SEEK_HEAD,
            ebml_constants.ID_TAGS,
            ebml_constants.ID_CHAPTERS => .metadata,

            ebml_constants.ID_TRACKS,
            ebml_constants.ID_TRACK_ENTRY,
            ebml_constants.ID_VIDEO,
            ebml_constants.ID_AUDIO => .track_info,

            ebml_constants.ID_CUES,
            ebml_constants.ID_CUE_POINT => .cluster_index,

            ebml_constants.ID_CLUSTER,
            ebml_constants.ID_SIMPLE_BLOCK,
            ebml_constants.ID_BLOCK_GROUP => .media_data,

            ebml_constants.ID_VOID,
            ebml_constants.ID_CRC32 => .padding,

            else => .unknown,
        };
    }
};
