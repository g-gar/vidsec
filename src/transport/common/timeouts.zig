const std = @import("std");

/// Common network timeout thresholds in milliseconds.
pub const NetworkTimeouts = struct {
    connect_timeout_ms: u64 = 10_000,
    read_timeout_ms: u64 = 30_000,
    write_timeout_ms: u64 = 30_000,
    pool_acquire_timeout_ms: u64 = 5_000,
    idle_connection_timeout_ms: u64 = 60_000,
};
