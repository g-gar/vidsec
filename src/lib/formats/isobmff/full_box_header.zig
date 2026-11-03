const std = @import("std");
const BoxHeader = @import("box_header.zig").BoxHeader;

/// FullBox header extending a standard Box with 1-byte version and 3-byte (24-bit) flags.
pub const FullBoxHeader = struct {
    box: BoxHeader,
    version: u8,
    flags: u24,

    pub fn payloadOffset(self: FullBoxHeader) u64 {
        return self.box.payloadOffset() + 4;
    }

    pub fn payloadSize(self: FullBoxHeader) u64 {
        const p_size = self.box.payloadSize();
        return p_size -| 4;
    }
};
