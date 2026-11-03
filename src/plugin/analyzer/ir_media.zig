const std = @import("std");
const abi = @import("vidsec_abi");
const media = @import("media/mod.zig");

pub const LowerMediaInputs = struct {
    detected_family: []const u8 = "",
};

/// Task `ir/lower_media`:
/// Normalizes format-specific track and codec tables into unified `ir_codec_configs`
/// and `ir_sample_extents` using a format-specific Lowering Strategy.
/// Requires NO stream access — operates 100% on probed in-memory track data.
pub fn runLowerMedia(ctx: abi.TaskContext, inputs: LowerMediaInputs) abi.SdkError!abi.TaskStatus_ABI {
    var config_counter: i64 = 1;

    // 1. Resolve detected_family from bound inputs
    const family = inputs.detected_family;

    // 2. Dispatch to format lowering strategy via Factory
    if (media.getMediaLoweringStrategy(family)) |strat| {
        try strat.lower_tracks(ctx, &config_counter);
    } else {
        // Fallback: try known format strategies if family was not specified
        try media.lowerMp4Tracks(ctx, &config_counter);
        if (config_counter == 1) {
            try media.lowerMkvTracks(ctx, &config_counter);
        }
    }

    // 3. Lower sample extents if available
    try media.lowerSampleExtents(ctx);

    return .ok;
}
