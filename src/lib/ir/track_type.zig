const std = @import("std");

/// Universal media track types.
pub const TrackType = enum(u8) {
    unknown = 0,
    video = 1,
    audio = 2,
    subtitle = 3,
    data = 4,

    pub fn asText(self: TrackType) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .video => "video",
            .audio => "audio",
            .subtitle => "subtitle",
            .data => "data",
        };
    }
};
