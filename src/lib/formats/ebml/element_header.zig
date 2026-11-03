const std = @import("std");

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
