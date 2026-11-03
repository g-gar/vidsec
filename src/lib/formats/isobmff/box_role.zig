const std = @import("std");
const FourCC = @import("fourcc.zig").FourCC;
const box_constants = @import("box_constants.zig");

/// Role classification for the Intermediate Representation (IR).
pub const BoxRole = enum {
    header,
    metadata,
    media_data,
    index,
    padding,
    unknown,

    pub fn asText(self: BoxRole) []const u8 {
        return switch (self) {
            .header => "header",
            .metadata => "metadata",
            .media_data => "media_data",
            .index => "index",
            .padding => "padding",
            .unknown => "unknown",
        };
    }

    /// Maps a standard ISOBMFF FourCC to its default IR role.
    pub fn fromFourCC(fourcc: FourCC) BoxRole {
        if (fourcc.equals(box_constants.BOX_FTYP) or fourcc.equals(box_constants.BOX_PDIN)) return .header;
        if (fourcc.equals(box_constants.BOX_MDAT)) return .media_data;
        if (box_constants.isPaddingBox(fourcc)) return .padding;
        if (fourcc.equals(box_constants.BOX_STCO) or
            fourcc.equals(box_constants.BOX_CO64) or
            fourcc.equals(box_constants.BOX_STSC) or
            fourcc.equals(box_constants.BOX_STSZ) or
            fourcc.equals(box_constants.BOX_STZ2) or
            fourcc.equals(box_constants.BOX_STTS) or
            fourcc.equals(box_constants.BOX_CTTS) or
            fourcc.equals(box_constants.BOX_STSS) or
            fourcc.equals(box_constants.BOX_SIDX)) return .index;
        if (box_constants.isContainerBox(fourcc) or
            fourcc.equals(box_constants.BOX_MVHD) or
            fourcc.equals(box_constants.BOX_TKHD) or
            fourcc.equals(box_constants.BOX_MDHD) or
            fourcc.equals(box_constants.BOX_HDLR) or
            fourcc.equals(box_constants.BOX_VMHD) or
            fourcc.equals(box_constants.BOX_SMHD) or
            fourcc.equals(box_constants.BOX_STSD) or
            fourcc.equals(box_constants.BOX_META) or
            fourcc.equals(box_constants.BOX_XML) or
            fourcc.equals(box_constants.BOX_BXML) or
            fourcc.equals(box_constants.BOX_CHPL) or
            fourcc.equals(box_constants.BOX_UUID)) return .metadata;

        return .unknown;
    }
};
