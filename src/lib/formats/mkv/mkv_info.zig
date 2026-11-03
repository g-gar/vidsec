pub const MkvInfo = struct {
    timecode_scale: u64 = 1_000_000, // nanoseconds per tick (1ms default)
    duration_ticks: f64 = 0.0,
    muxing_app: []const u8 = "",
    writing_app: []const u8 = "",

    pub fn durationSeconds(self: MkvInfo) f64 {
        if (self.timecode_scale == 0) return 0.0;
        const total_ns = self.duration_ticks * @as(f64, @floatFromInt(self.timecode_scale));
        return total_ns / 1_000_000_000.0;
    }
};
