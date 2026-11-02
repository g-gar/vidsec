const std = @import("std");
const types = @import("types.zig");
const sdk = @import("sdk.zig");

pub const SdkError = sdk.SdkError;
pub const TaskContext = sdk.TaskContext;
pub const WindowView_ABI = types.WindowView_ABI;

/// Result of creating a child `BoundedStreamReader` where the child's declared end offset
/// may exceed the parent's boundary or overflow 64-bit arithmetic (`R03` anomaly detection).
pub const ClampedSubRegion = struct {
    reader: BoundedStreamReader,
    is_truncated_or_overflow: bool,
};

/// Capability-mediated, bounds-checked byte reader backed by `TaskContext.streamReadAt`.
/// Enforces that every read stays strictly within `[base_offset, end_offset)` where `end_offset <= streamSize()`.
/// Supports nested sub-regions so container walkers (`isobmff`, `ebml`, `riff`) can never read past parent box/chunk boundaries.
pub const BoundedStreamReader = struct {
    ctx: TaskContext,
    base_offset: u64,
    end_offset: u64,
    cursor: u64,

    /// Initializes a reader covering the entire authorized input stream `[0, ctx.streamSize())`.
    pub fn fromStream(ctx: TaskContext) BoundedStreamReader {
        const total = ctx.streamSize();
        return .{
            .ctx = ctx,
            .base_offset = 0,
            .end_offset = total,
            .cursor = 0,
        };
    }

    /// Returns the total byte length of this bounded region (`end_offset - base_offset`).
    pub fn len(self: BoundedStreamReader) u64 {
        return self.end_offset - self.base_offset;
    }

    /// Returns the number of unread bytes between `cursor` and `end_offset`.
    pub fn remaining(self: BoundedStreamReader) u64 {
        if (self.cursor >= self.end_offset) return 0;
        return self.end_offset - self.cursor;
    }

    /// Returns `true` if `cursor` has reached `end_offset`.
    pub fn isEof(self: BoundedStreamReader) bool {
        return self.cursor >= self.end_offset;
    }

    /// Creates a strict sub-region `[abs_start, abs_end)` inside `[self.base_offset, self.end_offset]`.
    /// Returns `error.OutOfBounds` if the requested range falls outside the parent region.
    pub fn subRegion(self: BoundedStreamReader, abs_start: u64, abs_end: u64) SdkError!BoundedStreamReader {
        if (abs_start < self.base_offset or abs_end < abs_start or abs_end > self.end_offset) {
            return error.OutOfBounds;
        }
        return .{
            .ctx = self.ctx,
            .base_offset = abs_start,
            .end_offset = abs_end,
            .cursor = abs_start,
        };
    }

    /// Creates a sub-region starting at `abs_start` with declared byte length `declared_len`,
    /// clamping its end to `self.end_offset` and flagging `is_truncated_or_overflow = true`
    /// if `abs_start + declared_len` overflows `u64` or exceeds `self.end_offset` (`R03`).
    pub fn subRegionWithLengthClamped(
        self: BoundedStreamReader,
        abs_start: u64,
        declared_len: u64,
    ) SdkError!ClampedSubRegion {
        if (abs_start < self.base_offset or abs_start > self.end_offset) {
            return error.OutOfBounds;
        }
        const raw_end = std.math.add(u64, abs_start, declared_len) catch {
            return .{
                .reader = .{
                    .ctx = self.ctx,
                    .base_offset = abs_start,
                    .end_offset = self.end_offset,
                    .cursor = abs_start,
                },
                .is_truncated_or_overflow = true,
            };
        };
        if (raw_end > self.end_offset) {
            return .{
                .reader = .{
                    .ctx = self.ctx,
                    .base_offset = abs_start,
                    .end_offset = self.end_offset,
                    .cursor = abs_start,
                },
                .is_truncated_or_overflow = true,
            };
        }
        return .{
            .reader = .{
                .ctx = self.ctx,
                .base_offset = abs_start,
                .end_offset = raw_end,
                .cursor = abs_start,
            },
            .is_truncated_or_overflow = false,
        };
    }

    // --- Random-Access Reads (Absolute File Offset within `[base_offset, end_offset)`) ---

    pub fn readAt(self: BoundedStreamReader, abs_offset: u64, dest: []u8) SdkError!void {
        if (abs_offset < self.base_offset) return error.OutOfBounds;
        const end = std.math.add(u64, abs_offset, dest.len) catch return error.OutOfBounds;
        if (end > self.end_offset) return error.OutOfBounds;
        return self.ctx.streamReadAt(abs_offset, dest);
    }

    pub fn readU8At(self: BoundedStreamReader, abs_offset: u64) SdkError!u8 {
        var buf: [1]u8 = undefined;
        try self.readAt(abs_offset, &buf);
        return buf[0];
    }

    pub fn readU16BeAt(self: BoundedStreamReader, abs_offset: u64) SdkError!u16 {
        var buf: [2]u8 = undefined;
        try self.readAt(abs_offset, &buf);
        return std.mem.readInt(u16, &buf, .big);
    }

    pub fn readU16LeAt(self: BoundedStreamReader, abs_offset: u64) SdkError!u16 {
        var buf: [2]u8 = undefined;
        try self.readAt(abs_offset, &buf);
        return std.mem.readInt(u16, &buf, .little);
    }

    pub fn readU24BeAt(self: BoundedStreamReader, abs_offset: u64) SdkError!u24 {
        var buf: [3]u8 = undefined;
        try self.readAt(abs_offset, &buf);
        return std.mem.readInt(u24, &buf, .big);
    }

    pub fn readU32BeAt(self: BoundedStreamReader, abs_offset: u64) SdkError!u32 {
        var buf: [4]u8 = undefined;
        try self.readAt(abs_offset, &buf);
        return std.mem.readInt(u32, &buf, .big);
    }

    pub fn readU32LeAt(self: BoundedStreamReader, abs_offset: u64) SdkError!u32 {
        var buf: [4]u8 = undefined;
        try self.readAt(abs_offset, &buf);
        return std.mem.readInt(u32, &buf, .little);
    }

    pub fn readU64BeAt(self: BoundedStreamReader, abs_offset: u64) SdkError!u64 {
        var buf: [8]u8 = undefined;
        try self.readAt(abs_offset, &buf);
        return std.mem.readInt(u64, &buf, .big);
    }

    pub fn readU64LeAt(self: BoundedStreamReader, abs_offset: u64) SdkError!u64 {
        var buf: [8]u8 = undefined;
        try self.readAt(abs_offset, &buf);
        return std.mem.readInt(u64, &buf, .little);
    }

    pub fn readFourCCAt(self: BoundedStreamReader, abs_offset: u64) SdkError![4]u8 {
        var buf: [4]u8 = undefined;
        try self.readAt(abs_offset, &buf);
        return buf;
    }

    // --- Sequential Cursor Operations ---

    pub fn seekTo(self: *BoundedStreamReader, abs_offset: u64) SdkError!void {
        if (abs_offset < self.base_offset or abs_offset > self.end_offset) {
            return error.OutOfBounds;
        }
        self.cursor = abs_offset;
    }

    pub fn skip(self: *BoundedStreamReader, byte_count: u64) SdkError!void {
        const next_pos = std.math.add(u64, self.cursor, byte_count) catch return error.OutOfBounds;
        if (next_pos > self.end_offset) return error.OutOfBounds;
        self.cursor = next_pos;
    }

    pub fn readBytes(self: *BoundedStreamReader, dest: []u8) SdkError!void {
        try self.readAt(self.cursor, dest);
        self.cursor += dest.len;
    }

    pub fn readU8(self: *BoundedStreamReader) SdkError!u8 {
        const val = try self.readU8At(self.cursor);
        self.cursor += 1;
        return val;
    }

    pub fn readU16Be(self: *BoundedStreamReader) SdkError!u16 {
        const val = try self.readU16BeAt(self.cursor);
        self.cursor += 2;
        return val;
    }

    pub fn readU16Le(self: *BoundedStreamReader) SdkError!u16 {
        const val = try self.readU16LeAt(self.cursor);
        self.cursor += 2;
        return val;
    }

    pub fn readU24Be(self: *BoundedStreamReader) SdkError!u24 {
        const val = try self.readU24BeAt(self.cursor);
        self.cursor += 3;
        return val;
    }

    pub fn readU32Be(self: *BoundedStreamReader) SdkError!u32 {
        const val = try self.readU32BeAt(self.cursor);
        self.cursor += 4;
        return val;
    }

    pub fn readU32Le(self: *BoundedStreamReader) SdkError!u32 {
        const val = try self.readU32LeAt(self.cursor);
        self.cursor += 4;
        return val;
    }

    pub fn readU64Be(self: *BoundedStreamReader) SdkError!u64 {
        const val = try self.readU64BeAt(self.cursor);
        self.cursor += 8;
        return val;
    }

    pub fn readU64Le(self: *BoundedStreamReader) SdkError!u64 {
        const val = try self.readU64LeAt(self.cursor);
        self.cursor += 8;
        return val;
    }

    pub fn readFourCC(self: *BoundedStreamReader) SdkError![4]u8 {
        const val = try self.readFourCCAt(self.cursor);
        self.cursor += 4;
        return val;
    }
};

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
