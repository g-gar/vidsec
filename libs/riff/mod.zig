//! Pure RIFF / AVI container parser and `media_ir` lowerer.

const std = @import("std");

pub const riff = @import("riff/mod.zig");
pub const lower = @import("lower.zig");

pub const lowerContainer = lower.lowerContainer;

test {
    std.testing.refAllDecls(@This());
}
