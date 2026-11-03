const std = @import("std");
const TrackType = @import("track_type.zig").TrackType;

/// Normalized media track (video, audio, subtitle, or data).
pub const Track = struct {
    id: u32,
    kind: TrackType = .unknown,
    codec_tag: [4]u8 = [_]u8{ '?', '?', '?', '?' },
    container_width: u32 = 0,
    container_height: u32 = 0,
    bitstream_width: u32 = 0,
    bitstream_height: u32 = 0,
    timescale: u32 = 0,
    duration_ticks: u64 = 0,

    /// Checks container dimension vs bitstream SPS dimension discrepancy.
    pub fn hasDimensionMismatch(self: Track) bool {
        if (self.kind != .video) return false;
        if (self.container_width == 0 or self.bitstream_width == 0) return false;
        return (self.container_width != self.bitstream_width or
            self.container_height != self.bitstream_height);
    }

    /// Computes duration in seconds if timescale is specified.
    pub fn durationSeconds(self: Track) ?f64 {
        if (self.timescale == 0) return null;
        return @as(f64, @floatFromInt(self.duration_ticks)) / @as(f64, @floatFromInt(self.timescale));
    }
};
