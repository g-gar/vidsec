const FourCC = @import("fourcc.zig").FourCC;
const riff_constants = @import("riff_constants.zig");

/// High-level role of a RIFF chunk in container forensic analysis.
pub const ChunkRole = enum {
    header,
    metadata,
    stream_header,
    media_data,
    index,
    padding,
    unknown,

    pub fn asText(self: ChunkRole) []const u8 {
        return switch (self) {
            .header => "header",
            .metadata => "metadata",
            .stream_header => "stream_header",
            .media_data => "media_data",
            .index => "index",
            .padding => "padding",
            .unknown => "unknown",
        };
    }

    pub fn fromFourCC(fourcc: FourCC, list_type: ?FourCC) ChunkRole {
        if (fourcc.equals(riff_constants.FOURCC_RIFF) or
            fourcc.equals(riff_constants.FOURCC_RIFX) or
            fourcc.equals(riff_constants.FOURCC_RF64))
        {
            return .header;
        }
        if (fourcc.equals(riff_constants.FOURCC_LIST)) {
            if (list_type) |lt| {
                if (lt.equals(riff_constants.LIST_MOVI)) return .media_data;
                if (lt.equals(riff_constants.LIST_HDRL) or lt.equals(riff_constants.LIST_STRL)) return .stream_header;
                if (lt.equals(riff_constants.LIST_INFO)) return .metadata;
            }
            return .metadata;
        }
        if (fourcc.equals(riff_constants.CHUNK_AVIH) or
            fourcc.equals(riff_constants.CHUNK_STRH) or
            fourcc.equals(riff_constants.CHUNK_STRF) or
            fourcc.equals(riff_constants.CHUNK_FMT))
        {
            return .stream_header;
        }
        if (fourcc.equals(riff_constants.CHUNK_IDX1) or
            fourcc.equals(riff_constants.CHUNK_INDX))
        {
            return .index;
        }
        if (fourcc.equals(riff_constants.CHUNK_JUNK) or
            fourcc.equals(riff_constants.CHUNK_PAD))
        {
            return .padding;
        }
        if (fourcc.equals(riff_constants.CHUNK_DATA)) {
            return .media_data;
        }
        return .unknown;
    }
};
