const std = @import("std");

/// 4-character code (FourCC) identifying an ISOBMFF box/atom.
pub const FourCC = struct {
    bytes: [4]u8,

    pub fn init(str: *const [4]u8) FourCC {
        return .{ .bytes = str.* };
    }

    pub fn fromSlice(slice: []const u8) ?FourCC {
        if (slice.len < 4) return null;
        return .{ .bytes = slice[0..4].* };
    }

    pub fn fromInt(val: u32) FourCC {
        return .{ .bytes = std.mem.nativeToBig(u32, val) };
    }

    pub fn toBigEndianInt(self: FourCC) u32 {
        return std.mem.readInt(u32, &self.bytes, .big);
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

    pub fn format(
        self: FourCC,
        writer: anytype,
    ) !void {
        if (self.isPrintable()) {
            try writer.print("{s}", .{self.bytes});
        } else {
            try writer.print("0x{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{
                self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3],
            });
        }
    }
};
