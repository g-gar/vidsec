const std = @import("std");

/// Normalized sample extent pointing to the physical media payload.
pub const SampleExtent = struct {
    extent_id: u32,
    track_id: u32,
    target_offset: u64,
    byte_size: u64,
    pts: i64 = 0,
    dts: i64 = 0,
    is_keyframe: bool = false,

    /// Returns the physical end offset for this sample.
    pub fn endOffset(self: SampleExtent) u64 {
        const end, const overflow = @addWithOverflow(self.target_offset, self.byte_size);
        if (overflow != 0) return std.math.maxInt(u64);
        return end;
    }

    /// Checks if this sample points outside the physical file bounds.
    pub fn isOverflow(self: SampleExtent, file_size: u64) bool {
        return self.endOffset() > file_size;
    }
};
