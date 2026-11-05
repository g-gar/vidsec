const LogLevel_ABI = @import("log_level_abi.zig").LogLevel_ABI;

/// C-ABI callback signature for structured logging and telemetry.
pub const LogFn_ABI = *const fn (
    level: LogLevel_ABI,
    message_ptr: [*]const u8,
    message_len: usize,
) callconv(.c) void;

/// C-ABI runtime execution parameters passed to task entrypoints.
pub const ExecutionOptions_ABI = extern struct {
    /// Maximum worker threads allocated for data parallelism.
    workers: u32 = 1,
    /// Bitflags for task-specific execution flags.
    flags: u32 = 0,
    /// Optional host logging callback.
    log_fn: ?LogFn_ABI = null,
};
