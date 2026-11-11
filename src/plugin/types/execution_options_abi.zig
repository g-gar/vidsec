const LogLevel_ABI = @import("log_level_abi.zig").LogLevel_ABI;
const net_abi = @import("net_abi.zig");
const NetRequestFn_ABI = net_abi.NetRequestFn_ABI;

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
    /// Opaque pointer to the step's bound Virtual Network Adapter state.
    opaque_net_ctx: ?*anyopaque = null,
    /// Optional host network request callback for tasks bound to a `network:` adapter.
    net_request_fn: ?NetRequestFn_ABI = null,
    /// Optional host worker pool pointer for intra-step data parallelism.
    opaque_worker_pool: ?*anyopaque = null,
};
