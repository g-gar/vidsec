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

/// 4-byte ASCII Four-Character Code used by RIFF.
pub const FourCC = struct {
    bytes: [4]u8,

    pub fn init(str: *const [4]u8) FourCC {
        return .{ .bytes = str.* };
    }

    pub fn fromSlice(slice: []const u8) ?FourCC {
        if (slice.len < 4) return null;
        return FourCC{ .bytes = slice[0..4].* };
    }

    pub fn equals(self: FourCC, other: FourCC) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn isPrintable(self: FourCC) bool {
        for (self.bytes) |b| {
            if (b < 32 or b > 126) return false;
        }
        return true;
    }

    pub fn format(self: FourCC, writer: anytype) !void {
        try writer.writeAll(&self.bytes);
    }
};

// ============================================================================
// Standard RIFF Identifiers and Types
// ============================================================================

// Root Container Types
pub const FOURCC_RIFF = FourCC.init("RIFF"); // Little-endian standard RIFF
pub const FOURCC_RIFX = FourCC.init("RIFX"); // Big-endian RIFF
pub const FOURCC_RF64 = FourCC.init("RF64"); // 64-bit extensible RIFF
pub const FOURCC_LIST = FourCC.init("LIST"); // Container chunk

// Common Form Types
pub const FORM_AVI  = FourCC.init("AVI ");
pub const FORM_AVIX = FourCC.init("AVIX");
pub const FORM_WAVE = FourCC.init("WAVE");
pub const FORM_WEBP = FourCC.init("WEBP");
pub const FORM_ACON = FourCC.init("ACON");

// Common List Types
pub const LIST_HDRL = FourCC.init("hdrl"); // AVI header list
pub const LIST_MOVI = FourCC.init("movi"); // AVI movie data list
pub const LIST_STRL = FourCC.init("strl"); // AVI stream list
pub const LIST_ODML = FourCC.init("odml"); // OpenDML extended AVI
pub const LIST_INFO = FourCC.init("INFO"); // Metadata list

// Common Chunk Types
pub const CHUNK_AVIH = FourCC.init("avih"); // Main AVI header
pub const CHUNK_STRH = FourCC.init("strh"); // Stream header
pub const CHUNK_STRF = FourCC.init("strf"); // Stream format
pub const CHUNK_STRD = FourCC.init("strd"); // Stream data
pub const CHUNK_STRN = FourCC.init("strn"); // Stream name
pub const CHUNK_IDX1 = FourCC.init("idx1"); // Legacy AVI index
pub const CHUNK_INDX = FourCC.init("indx"); // OpenDML super index
pub const CHUNK_JUNK = FourCC.init("JUNK"); // Padding / dead space
pub const CHUNK_PAD  = FourCC.init("PAD "); // Padding
pub const CHUNK_FMT  = FourCC.init("fmt "); // WAVE format chunk
pub const CHUNK_DATA = FourCC.init("data"); // WAVE audio data

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
        if (fourcc.equals(FOURCC_RIFF) or fourcc.equals(FOURCC_RIFX) or fourcc.equals(FOURCC_RF64)) {
            return .header;
        }
        if (fourcc.equals(FOURCC_LIST)) {
            if (list_type) |lt| {
                if (lt.equals(LIST_MOVI)) return .media_data;
                if (lt.equals(LIST_HDRL) or lt.equals(LIST_STRL)) return .stream_header;
                if (lt.equals(LIST_INFO)) return .metadata;
            }
            return .metadata;
        }
        if (fourcc.equals(CHUNK_AVIH) or fourcc.equals(CHUNK_STRH) or fourcc.equals(CHUNK_STRF) or fourcc.equals(CHUNK_FMT)) {
            return .stream_header;
        }
        if (fourcc.equals(CHUNK_IDX1) or fourcc.equals(CHUNK_INDX)) {
            return .index;
        }
        if (fourcc.equals(CHUNK_JUNK) or fourcc.equals(CHUNK_PAD)) {
            return .padding;
        }
        if (fourcc.equals(CHUNK_DATA)) {
            return .media_data;
        }
        return .unknown;
    }
};

/// Decoded RIFF Chunk Header.
pub const ChunkHeader = struct {
    fourcc: FourCC,
    size: u32,
    offset: u64,
    /// Form type (for root RIFF) or List type (for LIST chunk) if applicable
    form_or_list_type: ?FourCC = null,
    /// True if `size` is odd, which requires a 1-byte 0x00 pad after the payload
    is_padded: bool,

    pub fn headerSize(self: ChunkHeader) u64 {
        // Root RIFF and LIST chunks include 4 bytes of form/list type at the start of payload
        _ = self;
        return 8;
    }

    pub fn payloadOffset(self: ChunkHeader) u64 {
        if (self.form_or_list_type != null) {
            return self.offset + 12; // 8 bytes chunk header + 4 bytes form/list type
        }
        return self.offset + 8;
    }

    pub fn payloadSize(self: ChunkHeader) u64 {
        if (self.form_or_list_type != null) {
            return if (self.size >= 4) self.size - 4 else 0;
        }
        return self.size;
    }

    /// Total bytes consumed in stream including 8-byte header and optional word padding byte.
    pub fn totalSize(self: ChunkHeader) u64 {
        const pad_byte: u64 = if (self.is_padded) 1 else 0;
        return 8 + @as(u64, self.size) + pad_byte;
    }
};

/// An indexed chunk in the parsed RIFF container hierarchy.
pub const ParsedChunk = struct {
    id: u32,
    parent_id: ?u32,
    depth: u16,
    header: ChunkHeader,
    role: ChunkRole,
    child_count: u32 = 0,
};

/// Error conditions detected during RIFF structural inspection.
pub const ParserIssueCode = enum {
    riff_magic_invalid,
    root_size_too_small,
    chunk_size_overflow,
    chunk_extends_past_parent,
    truncated_chunk_header,
    nesting_depth_exceeded,
    missing_odd_byte_padding,
    trailing_unparsed_slack,

    pub fn asText(self: ParserIssueCode) []const u8 {
        return switch (self) {
            .riff_magic_invalid => "RIFF_MAGIC_INVALID",
            .root_size_too_small => "RIFF_ROOT_SIZE_TOO_SMALL",
            .chunk_size_overflow => "RIFF_CHUNK_SIZE_OVERFLOW",
            .chunk_extends_past_parent => "RIFF_CHUNK_EXTENDS_PAST_PARENT",
            .truncated_chunk_header => "RIFF_TRUNCATED_CHUNK_HEADER",
            .nesting_depth_exceeded => "RIFF_NESTING_DEPTH_EXCEEDED",
            .missing_odd_byte_padding => "RIFF_MISSING_ODD_BYTE_PADDING",
            .trailing_unparsed_slack => "RIFF_TRAILING_UNPARSED_SLACK",
        };
    }
};

pub const ParserIssue = struct {
    code: ParserIssueCode,
    offset: u64,
    fourcc: ?FourCC = null,
    details: []const u8,
};
