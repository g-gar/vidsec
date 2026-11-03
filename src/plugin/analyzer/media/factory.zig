const std = @import("std");
const strategy_mod = @import("strategy.zig");
const MediaLoweringStrategy = strategy_mod.MediaLoweringStrategy;
const Mp4MediaStrategy = @import("mp4_strategy.zig").Mp4MediaStrategy;
const MkvMediaStrategy = @import("mkv_strategy.zig").MkvMediaStrategy;

/// Resolves the corresponding format media lowering strategy based on the detected format family.
pub fn getMediaLoweringStrategy(family: []const u8) ?MediaLoweringStrategy {
    if (std.mem.eql(u8, family, "isobmff") or std.mem.eql(u8, family, "mp4")) {
        return Mp4MediaStrategy.strategy;
    } else if (std.mem.eql(u8, family, "ebml") or std.mem.eql(u8, family, "mkv")) {
        return MkvMediaStrategy.strategy;
    }
    return null;
}
