const std = @import("std");
const FourCC = @import("fourcc.zig").FourCC;

/// High-level header representation of an ISOBMFF Box.
pub const BoxHeader = struct {
    fourcc: FourCC,
    offset: u64,
    size: u64,
    header_size: u8,
    is_extended_size: bool,
    is_eof_size: bool,

    pub fn payloadOffset(self: BoxHeader) u64 {
        return self.offset + self.header_size;
    }

    pub fn payloadSize(self: BoxHeader) u64 {
        if (self.is_eof_size) return 0;
        return self.size -| self.header_size;
    }

    pub fn endOffset(self: BoxHeader) u64 {
        if (self.is_eof_size) return std.math.maxInt(u64);
        return self.offset + self.size;
    }
};
