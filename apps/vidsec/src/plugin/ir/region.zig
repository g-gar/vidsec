const std = @import("std");
const RegionRole = @import("region_role.zig").RegionRole;

/// Normalized structural container region (Box in ISOBMFF, Element in EBML, Chunk in RIFF).
pub const Region = struct {
    id: u32,
    parent_id: ?u32 = null,
    tag: [4]u8,
    role: RegionRole = .unknown,
    header_offset: u64,
    payload_offset: u64,
    size: u64,
    depth: u16 = 0,

    /// Returns the effective physical upper byte bound (offset + size).
    pub fn effectiveEnd(self: Region) u64 {
        const end, const overflow = @addWithOverflow(self.header_offset, self.size);
        if (overflow != 0) return std.math.maxInt(u64);
        return end;
    }

    /// Alias for effectiveEnd for format parser and auditor compatibility.
    pub fn endOffset(self: Region) u64 {
        return self.effectiveEnd();
    }

    /// Returns the header start offset.
    pub fn offset(self: Region) u64 {
        return self.header_offset;
    }

    /// Returns the payload byte length.
    pub fn payloadSize(self: Region) u64 {
        if (self.payload_offset < self.header_offset) return 0;
        const header_len = self.payload_offset - self.header_offset;
        if (self.size < header_len) return 0;
        return self.size - header_len;
    }

    /// Returns the header byte length.
    pub fn headerSize(self: Region) u64 {
        if (self.payload_offset < self.header_offset) return 0;
        return self.payload_offset - self.header_offset;
    }

    /// Checks if the declared region extends past the physical file boundary.
    pub fn isOverflow(self: Region, file_size: u64) bool {
        return self.effectiveEnd() > file_size;
    }

    pub fn tagSlice(self: *const Region) []const u8 {
        return &self.tag;
    }

    /// Alias for tagSlice for compatibility with idSlice.
    pub fn idSlice(self: *const Region) []const u8 {
        return self.tagSlice();
    }
};
