const FourCC = @import("fourcc.zig").FourCC;

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
