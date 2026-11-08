const std = @import("std");

/// Canonical network timeout thresholds in milliseconds.
/// Shared across both inbound (servers) and outbound (clients/adapters) transport layers.
pub const NetworkTimeouts = struct {
    connect_ms: u64 = 3_000,
    tls_handshake_ms: u64 = 3_000,
    read_idle_ms: u64 = 10_000,
    write_idle_ms: u64 = 5_000,
    pool_acquire_ms: u64 = 2_000,
    idle_connection_ms: u64 = 60_000,

    /// Helper returning connect timeout in milliseconds
    pub fn connectTimeoutMs(self: NetworkTimeouts) u64 {
        return self.connect_ms;
    }

    /// Helper returning read timeout in milliseconds
    pub fn readTimeoutMs(self: NetworkTimeouts) u64 {
        return self.read_idle_ms;
    }

    /// Helper returning write timeout in milliseconds
    pub fn writeTimeoutMs(self: NetworkTimeouts) u64 {
        return self.write_idle_ms;
    }
};
