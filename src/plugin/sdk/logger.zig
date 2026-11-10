const std = @import("std");
const types = @import("../types/mod.zig");
const TaskContext_ABI = types.TaskContext_ABI;
const LogLevel_ABI = types.LogLevel_ABI;

/// Lightweight, decoupled polymorphic logger.
/// Backed by VTable to support Host C-ABI logging, silent no-op (testing),
/// stderr (standalone CLI), or custom test capturing.
pub const Logger = struct {
    ptr: ?*anyopaque = null,
    vtable: *const VTable = &noop_vtable,

    pub const VTable = struct {
        log: *const fn (ctx: ?*anyopaque, level: LogLevel_ABI, msg: []const u8) void,
    };

    const noop_vtable = VTable{
        .log = &noopLogBridge,
    };

    fn noopLogBridge(_: ?*anyopaque, _: LogLevel_ABI, _: []const u8) void {}

    const host_vtable = VTable{
        .log = &hostLogBridge,
    };

    fn hostLogBridge(ctx: ?*anyopaque, level: LogLevel_ABI, msg: []const u8) void {
        if (ctx) |c| {
            const raw: *TaskContext_ABI = @ptrCast(@alignCast(c));
            raw.host.log_event(raw, level, msg.ptr, msg.len);
        }
    }

    const stderr_vtable = VTable{
        .log = &stderrLogBridge,
    };

    fn stderrLogBridge(_: ?*anyopaque, level: LogLevel_ABI, msg: []const u8) void {
        const lvl_str = switch (level) {
            .debug => "[DEBUG]",
            .info => "[INFO]",
            .warn => "[WARN]",
            .err => "[ERROR]",
        };
        const stderr_file = std.io.getStdErr().writer();
        stderr_file.print("{s} {s}\n", .{ lvl_str, msg }) catch {};
    }

    /// Production constructor binding to the Flowdata C-ABI host.
    pub fn init(raw: *TaskContext_ABI) Logger {
        return .{ .ptr = raw, .vtable = &host_vtable };
    }

    /// Silent no-op logger for unit testing.
    pub fn noop() Logger {
        return .{ .ptr = null, .vtable = &noop_vtable };
    }

    /// Logger writing formatted output to stderr.
    pub fn stderr() Logger {
        return .{ .ptr = null, .vtable = &stderr_vtable };
    }

    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log_event_truncated";
        self.vtable.log(self.ptr, .info, msg);
    }

    pub fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log_event_truncated";
        self.vtable.log(self.ptr, .warn, msg);
    }

    pub fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log_event_truncated";
        self.vtable.log(self.ptr, .err, msg);
    }
};
