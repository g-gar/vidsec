pub const MkvTrackType = enum(u8) {
    video = 1,
    audio = 2,
    complex = 3,
    logo = 0x10,
    subtitle = 0x11,
    buttons = 0x12,
    control = 0x20,
    unknown = 0xFF,

    pub fn fromInt(val: u64) MkvTrackType {
        return switch (val) {
            1 => .video,
            2 => .audio,
            3 => .complex,
            0x10 => .logo,
            0x11 => .subtitle,
            0x12 => .buttons,
            0x20 => .control,
            else => .unknown,
        };
    }

    pub fn asText(self: MkvTrackType) []const u8 {
        return switch (self) {
            .video => "video",
            .audio => "audio",
            .complex => "complex",
            .logo => "logo",
            .subtitle => "subtitle",
            .buttons => "buttons",
            .control => "control",
            .unknown => "unknown",
        };
    }
};
