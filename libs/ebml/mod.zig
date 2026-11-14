//! Pure EBML / Matroska (MKV / WebM) container parser and `media_ir` lowerer.

const std = @import("std");

pub const ebml = @import("ebml/mod.zig");
pub const mkv = @import("mkv/mod.zig");
pub const lower = @import("lower.zig");

pub const lowerContainer = lower.lowerContainer;

test {
    std.testing.refAllDecls(@This());
}
