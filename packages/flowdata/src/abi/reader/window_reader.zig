const sdk = @import("../sdk/mod.zig");
const types = @import("../types/mod.zig");

const SdkError = sdk.SdkError;
const TaskContext = sdk.TaskContext;
const WindowView_ABI = types.WindowView_ABI;

/// Capability-mediated, chunked reader over a single `WindowView_ABI` yielded by `ctx.nextWindow()`.
/// Enforces that reads stay strictly within `[0, window.byte_length)` via `TaskContext.windowReadAt`.
pub const WindowReader = struct {
    ctx: TaskContext,
    window: WindowView_ABI,
    rel_cursor: u64 = 0,

    pub fn init(ctx: TaskContext, window: WindowView_ABI) WindowReader {
        return .{
            .ctx = ctx,
            .window = window,
            .rel_cursor = 0,
        };
    }

    pub fn byteLength(self: WindowReader) u64 {
        return self.window.byte_length;
    }

    pub fn remaining(self: WindowReader) u64 {
        if (self.rel_cursor >= self.window.byte_length) return 0;
        return self.window.byte_length - self.rel_cursor;
    }

    pub fn readAt(self: WindowReader, rel_offset: u64, dest: []u8) SdkError!void {
        return self.ctx.windowReadAt(&self.window, rel_offset, dest);
    }

    /// Reads up to `buf.len` bytes from the current relative cursor, advancing `rel_cursor`
    /// and returning the slice of `buf` actually populated (or empty slice at EOF).
    pub fn readChunk(self: *WindowReader, buf: []u8) SdkError![]const u8 {
        const rem = self.remaining();
        if (rem == 0 or buf.len == 0) return &.{};
        const to_read: usize = @intCast(@min(rem, @as(u64, buf.len)));
        try self.ctx.windowReadAt(&self.window, self.rel_cursor, buf[0..to_read]);
        self.rel_cursor += to_read;
        return buf[0..to_read];
    }
};
