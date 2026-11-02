const std = @import("std");

/// Abstract byte source permitting zero-copy memory reads or lazy streaming reads.
pub const ByteSource = struct {
    ctx: *const anyopaque,
    read_at_fn: *const fn (ctx: *const anyopaque, buf: []u8, offset: u64) anyerror!usize,
    file_size: u64,

    pub fn readAt(self: ByteSource, buf: []u8, offset: u64) !usize {
        return self.read_at_fn(self.ctx, buf, offset);
    }

    pub fn fromSlice(slice: []const u8) ByteSource {
        const S = struct {
            var shared_len: usize = 0;
            var shared_ptr: [*]const u8 = undefined;

            fn readAtDirect(ctx_ptr: *const anyopaque, buf: []u8, offset: u64) anyerror!usize {
                _ = ctx_ptr;
                if (offset >= shared_len) return 0;
                const available = shared_len - offset;
                const to_read = @min(buf.len, available);
                @memcpy(buf[0..to_read], shared_ptr[offset .. offset + to_read]);
                return to_read;
            }
        };
        S.shared_len = slice.len;
        S.shared_ptr = slice.ptr;

        return .{
            .ctx = @ptrCast(slice.ptr),
            .read_at_fn = S.readAtDirect,
            .file_size = slice.len,
        };
    }
};

/// Decoded Variable Size Integer (VINT) per RFC 8794 Section 4.
pub const Vint = struct {
    /// Raw integer representation of the octet sequence (big-endian)
    raw_value: u64,
    /// Length of the VINT octet sequence (1 to 8 octets)
    length: u8,
    /// Numerical value with the leading length-marker bit cleared
    data_value: u64,
    /// True if all data bits are set to 1 (indicating unknown or undefined data size)
    is_all_ones: bool,
};

// ============================================================================
// Standard EBML and Matroska Container IDs
// ============================================================================

// EBML Header (RFC 8794)
pub const ID_EBML_HEADER           = 0x1A45DFA3; // Master
pub const ID_EBML_VERSION          = 0x4286;     // uint
pub const ID_EBML_READ_VERSION     = 0x42F7;     // uint
pub const ID_EBML_MAX_ID_LENGTH    = 0x42F2;     // uint
pub const ID_EBML_MAX_SIZE_LENGTH  = 0x42F3;     // uint
pub const ID_DOC_TYPE              = 0x4282;     // string
pub const ID_DOC_TYPE_VERSION      = 0x4287;     // uint
pub const ID_DOC_TYPE_READ_VERSION = 0x4285;     // uint
pub const ID_CRC32                 = 0xBF;       // binary (4 bytes)
pub const ID_VOID                  = 0xEC;       // binary (padding)

// Matroska Segment & Top-Level Elements
pub const ID_SEGMENT               = 0x18538067; // Master
pub const ID_SEEK_HEAD             = 0x114D9B74; // Master
pub const ID_SEEK_ENTRY            = 0x4DBB;     // Master
pub const ID_SEEK_ID               = 0x53AB;     // binary
pub const ID_SEEK_POSITION         = 0x53AC;     // uint

pub const ID_INFO                  = 0x1549A966; // Master
pub const ID_TIMECODE_SCALE        = 0x2AD7B1;   // uint
pub const ID_DURATION              = 0x4489;     // float
pub const ID_MUXING_APP            = 0x4D80;     // utf-8
pub const ID_WRITING_APP           = 0x5741;     // utf-8
pub const ID_DATE_UTC              = 0x4461;     // date

pub const ID_TRACKS                = 0x1654AE6B; // Master
pub const ID_TRACK_ENTRY           = 0xAE;       // Master
pub const ID_TRACK_NUMBER          = 0xD7;       // uint
pub const ID_TRACK_UID             = 0x73C5;     // uint
pub const ID_TRACK_TYPE            = 0x83;       // uint (1=video, 2=audio, 3=complex, 0x11=sub)
pub const ID_CODEC_ID              = 0x86;       // string
pub const ID_CODEC_PRIVATE         = 0x63A2;     // binary
pub const ID_CODEC_NAME            = 0x258688;   // utf-8
pub const ID_DEFAULT_DURATION      = 0x23E383;   // uint (ns per frame)

// Video & Audio sub-masters
pub const ID_VIDEO                 = 0xE0;       // Master
pub const ID_PIXEL_WIDTH           = 0xB0;       // uint
pub const ID_PIXEL_HEIGHT          = 0xBA;       // uint
pub const ID_DISPLAY_WIDTH         = 0x54B0;     // uint
pub const ID_DISPLAY_HEIGHT        = 0x54BA;     // uint

pub const ID_AUDIO                 = 0xE1;       // Master
pub const ID_SAMPLING_FREQUENCY    = 0xB5;       // float
pub const ID_CHANNELS              = 0x9F;       // uint
pub const ID_BIT_DEPTH             = 0x6264;     // uint

// Clusters & Media Blocks
pub const ID_CLUSTER               = 0x1F43B675; // Master
pub const ID_CLUSTER_TIMECODE      = 0xE7;       // uint
pub const ID_SIMPLE_BLOCK          = 0xA3;       // binary
pub const ID_BLOCK_GROUP           = 0xA0;       // Master
pub const ID_BLOCK                 = 0xA1;       // binary
pub const ID_BLOCK_DURATION        = 0x9B;       // uint

// Cues, Attachments, Chapters, Tags
pub const ID_CUES                  = 0x1C53BB6B; // Master
pub const ID_CUE_POINT             = 0xBB;       // Master
pub const ID_ATTACHMENTS           = 0x1941A469; // Master
pub const ID_ATTACHED_FILE         = 0x61A7;     // Master
pub const ID_FILE_NAME             = 0x466E;     // utf-8
pub const ID_FILE_MIME_TYPE        = 0x4660;     // string
pub const ID_FILE_DATA             = 0x465C;     // binary
pub const ID_CHAPTERS              = 0x1043A770; // Master
pub const ID_TAGS                  = 0x1254C367; // Master

/// Master Elements whose payload is formed entirely of nested sub-elements.
pub fn isMasterElement(id: u32) bool {
    return switch (id) {
        ID_EBML_HEADER,
        ID_SEGMENT,
        ID_SEEK_HEAD,
        ID_SEEK_ENTRY,
        ID_INFO,
        ID_TRACKS,
        ID_TRACK_ENTRY,
        ID_VIDEO,
        ID_AUDIO,
        ID_CLUSTER,
        ID_BLOCK_GROUP,
        ID_CUES,
        ID_CUE_POINT,
        ID_ATTACHMENTS,
        ID_ATTACHED_FILE,
        ID_CHAPTERS,
        ID_TAGS,
        => true,
        else => false,
    };
}

/// Decoded EBML Element Header.
pub const ElementHeader = struct {
    /// Element ID with length marker intact (e.g. 0x1A45DFA3)
    id: u32,
    /// Byte length of the Element ID VINT (1 to 4)
    id_len: u8,
    /// Data size in bytes (with length marker cleared)
    data_size: u64,
    /// Byte length of the Data Size VINT (1 to 8)
    size_len: u8,
    /// File offset where this element header starts
    offset: u64,
    /// True if data size had all data bits set to 1 (unknown size)
    is_unknown_size: bool,

    pub fn headerSize(self: ElementHeader) u64 {
        return @as(u64, self.id_len) + @as(u64, self.size_len);
    }

    pub fn payloadOffset(self: ElementHeader) u64 {
        return self.offset + self.headerSize();
    }

    pub fn totalSize(self: ElementHeader) u64 {
        return self.headerSize() +| self.data_size;
    }
};

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
            ID_EBML_HEADER => .header,
            ID_SEGMENT, ID_INFO, ID_SEEK_HEAD, ID_TAGS, ID_CHAPTERS => .metadata,
            ID_TRACKS, ID_TRACK_ENTRY, ID_VIDEO, ID_AUDIO => .track_info,
            ID_CUES, ID_CUE_POINT => .cluster_index,
            ID_CLUSTER, ID_SIMPLE_BLOCK, ID_BLOCK_GROUP => .media_data,
            ID_VOID, ID_CRC32 => .padding,
            else => .unknown,
        };
    }
};

/// A fully indexed EBML element in the parsed container hierarchy.
pub const ParsedElement = struct {
    id: u32,
    parent_id: ?u32,
    depth: u16,
    header: ElementHeader,
    role: ElementRole,
    child_count: u32 = 0,
};

/// Error conditions detected during EBML grammar parsing.
pub const ParserIssueCode = enum {
    vint_invalid_lead_zero,
    vint_exceeds_max_octets,
    id_length_exceeds_4_bytes,
    size_extends_beyond_eof,
    element_header_truncated,
    nesting_depth_exceeded,
    ebml_header_not_first,
    duplicate_ebml_header,
    missing_ebml_header,
    unsupported_doc_type,
    trailing_unparsed_slack,

    pub fn asText(self: ParserIssueCode) []const u8 {
        return switch (self) {
            .vint_invalid_lead_zero => "EBML_VINT_INVALID_LEAD_ZERO",
            .vint_exceeds_max_octets => "EBML_VINT_EXCEEDS_MAX_OCTETS",
            .id_length_exceeds_4_bytes => "EBML_ID_LENGTH_EXCEEDS_4_BYTES",
            .size_extends_beyond_eof => "EBML_SIZE_EXTENDS_BEYOND_EOF",
            .element_header_truncated => "EBML_ELEMENT_HEADER_TRUNCATED",
            .nesting_depth_exceeded => "EBML_NESTING_DEPTH_EXCEEDED",
            .ebml_header_not_first => "EBML_HEADER_NOT_FIRST",
            .duplicate_ebml_header => "EBML_DUPLICATE_HEADER",
            .missing_ebml_header => "EBML_MISSING_HEADER",
            .unsupported_doc_type => "EBML_UNSUPPORTED_DOC_TYPE",
            .trailing_unparsed_slack => "EBML_TRAILING_UNPARSED_SLACK",
        };
    }
};

pub const ParserIssue = struct {
    code: ParserIssueCode,
    offset: u64,
    element_id: ?u32 = null,
    details: []const u8,
};
