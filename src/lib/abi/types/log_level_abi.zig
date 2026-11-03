/// Structured log severity level passed to `HostApiVTable_ABI.log_event`.
pub const LogLevel_ABI = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};
