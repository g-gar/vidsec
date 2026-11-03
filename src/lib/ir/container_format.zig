const std = @import("std");

/// Normalized container format code.
pub const ContainerFormat = enum(u8) {
    unknown = 0,
    isobmff = 1,
    ebml = 2,
    riff = 3,
    mpegts = 4,

    pub fn asText(self: ContainerFormat) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .isobmff => "isobmff",
            .ebml => "ebml",
            .riff => "riff",
            .mpegts => "mpegts",
        };
    }

    pub fn toInt(self: ContainerFormat) i64 {
        return @intFromEnum(self);
    }
};
