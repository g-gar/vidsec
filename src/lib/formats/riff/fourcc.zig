const std = @import("std");

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
