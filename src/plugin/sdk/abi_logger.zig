const types = @import("../types/mod.zig");
const LogLevel_ABI = types.LogLevel_ABI;
const LogFn_ABI = types.LogFn_ABI;

/// Lightweight logging wrapper for pure Black Box tasks.
pub const AbiLogger = struct {
    log_fn: ?LogFn_ABI = null,

    pub fn debug(self: AbiLogger, msg: []const u8) void {
        if (self.log_fn) |f| f(.debug, msg.ptr, msg.len);
    }

    pub fn info(self: AbiLogger, msg: []const u8) void {
        if (self.log_fn) |f| f(.info, msg.ptr, msg.len);
    }

    pub fn warn(self: AbiLogger, msg: []const u8) void {
        if (self.log_fn) |f| f(.warn, msg.ptr, msg.len);
    }

    pub fn err(self: AbiLogger, msg: []const u8) void {
        if (self.log_fn) |f| f(.err, msg.ptr, msg.len);
    }
};
