//! Pure ISOBMFF / MP4 container parser and `media_ir` lowerer.

const std = @import("std");

pub const box = @import("box/mod.zig");
pub const mp4 = @import("mp4/mod.zig");
pub const lower = @import("lower.zig");

pub const lowerContainer = lower.lowerContainer;

test {
    std.testing.refAllDecls(@This());
}
