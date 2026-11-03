const std = @import("std");
const ByteStream = @import("byte_stream.zig").ByteStream;

/// Slice-backed in-memory implementation of `ByteStream`.
pub const SliceStream = struct {
    slice: []const u8,

    pub fn init(slice: []const u8) SliceStream {
        return .{ .slice = slice };
    }

    pub fn byteStream(self: *const SliceStream) ByteStream {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = ByteStream.VTable{
        .readAt = readAtImpl,
        .size = sizeImpl,
    };

    fn readAtImpl(ctx: *const anyopaque, offset: u64, dest: []u8) error{ ReadFailed, EndOfStream }!usize {
        const self: *const SliceStream = @ptrCast(@alignCast(ctx));
        if (offset >= self.slice.len) return error.EndOfStream;
        const available = self.slice.len - offset;
        const to_read = @min(dest.len, available);
        @memcpy(dest[0..to_read], self.slice[offset .. offset + to_read]);
        return to_read;
    }

    fn sizeImpl(ctx: *const anyopaque) u64 {
        const self: *const SliceStream = @ptrCast(@alignCast(ctx));
        return self.slice.len;
    }
};
