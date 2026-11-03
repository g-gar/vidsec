const std = @import("std");
const types = @import("../types/mod.zig");
const TaskContext_ABI = types.TaskContext_ABI;
const LogLevel_ABI = types.LogLevel_ABI;

/// Lightweight, decoupled logger passed to pure tasks.
/// Formats messages using a zero-allocation stack buffer before dispatching to the host.
pub const Logger = struct {
    raw: *TaskContext_ABI,

    pub fn init(raw: *TaskContext_ABI) Logger {
        return .{ .raw = raw };
    }

    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log_event_truncated";
        self.raw.host.log_event(self.raw, .info, msg.ptr, msg.len);
    }

    pub fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log_event_truncated";
        self.raw.host.log_event(self.raw, .warn, msg.ptr, msg.len);
    }

    pub fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log_event_truncated";
        self.raw.host.log_event(self.raw, .err, msg.ptr, msg.len);
    }
};
