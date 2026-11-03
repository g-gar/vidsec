const std = @import("std");

/// Universal structural roles for IR regions.
pub const RegionRole = enum(u8) {
    unknown = 0,
    header = 1,
    container = 2,
    metadata = 3,
    media_data = 4,
    index = 5,
    padding = 6,
    codec_config = 7,
    attachment = 8,

    pub fn asText(self: RegionRole) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .header => "header",
            .container => "container",
            .metadata => "metadata",
            .media_data => "media_data",
            .index => "index",
            .padding => "padding",
            .codec_config => "codec_config",
            .attachment => "attachment",
        };
    }

    pub fn parse(s: []const u8) RegionRole {
        if (std.mem.eql(u8, s, "header")) return .header;
        if (std.mem.eql(u8, s, "container")) return .container;
        if (std.mem.eql(u8, s, "metadata")) return .metadata;
        if (std.mem.eql(u8, s, "media_data")) return .media_data;
        if (std.mem.eql(u8, s, "index")) return .index;
        if (std.mem.eql(u8, s, "padding")) return .padding;
        if (std.mem.eql(u8, s, "codec_config")) return .codec_config;
        if (std.mem.eql(u8, s, "attachment")) return .attachment;
        return .unknown;
    }
};
