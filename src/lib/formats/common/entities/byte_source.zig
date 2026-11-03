const std = @import("std");

/// Generic zero-copy byte source interface (supports slices and positional stream readers).
pub const ByteSource = struct {
    ctx: *const anyopaque,
    read_at_fn: *const fn (ctx: *const anyopaque, buf: []u8, offset: u64) anyerror!usize,
    file_size: u64,

    pub fn readAt(self: ByteSource, buf: []u8, offset: u64) !usize {
        if (offset >= self.file_size) return 0;
        const available = self.file_size - offset;
        const to_read = @min(buf.len, available);
        if (to_read == 0) return 0;
        return self.read_at_fn(self.ctx, buf[0..to_read], offset);
    }

    /// Creates a ByteSource wrapping a contiguous slice of memory.
    pub fn fromSlice(slice: []const u8) ByteSource {
        const Wrapper = struct {
            fn readSlice(ctx_ptr: *const anyopaque, buf: []u8, offset: u64) anyerror!usize {
                const ptr: [*]const u8 = @ptrCast(ctx_ptr);
                @memcpy(buf, ptr[offset .. offset + buf.len]);
                return buf.len;
            }
        };

        return .{
            .ctx = @ptrCast(slice.ptr),
            .read_at_fn = Wrapper.readSlice,
            .file_size = slice.len,
        };
    }
};
