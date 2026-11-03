const Logger = @import("logger.zig").Logger;

/// Specification for a decoupled pure task function that takes `Inputs` and returns `Outputs`.
pub fn PureTaskSpec(comptime Inputs: type, comptime Outputs: type) type {
    return struct {
        name: [:0]const u8,
        description: [:0]const u8 = "",
        output_channel: ?[:0]const u8 = null,
        run: *const fn (inputs: Inputs) anyerror!Outputs,
    };
}

/// Specification for a pure task function that takes `Inputs` and a decoupled `Logger`.
pub fn PureTaskWithLoggerSpec(comptime Inputs: type, comptime Outputs: type) type {
    return struct {
        name: [:0]const u8,
        description: [:0]const u8 = "",
        output_channel: ?[:0]const u8 = null,
        run: *const fn (inputs: Inputs, log: Logger) anyerror!Outputs,
    };
}
