const std = @import("std");
const abi = @import("vidsec_abi");
const mp4_strategy = @import("mp4_strategy.zig");
const samples_strategy = @import("samples_strategy.zig");

pub const LowerMp4MediaInputs = struct {};

/// Lowers MP4 tracks from `tracks` (or `mp4_tracks`) into `ir_codec_configs`
/// and lowers sample extents from `samples` (or `sample_extents`) into `ir_sample_extents`.
pub fn runLowerMp4Media(
    ctx: abi.TaskContext,
    _: LowerMp4MediaInputs,
) abi.SdkError!abi.TaskStatus_ABI {
    var config_counter: i64 = 1;
    try mp4_strategy.lowerMp4Tracks(ctx, &config_counter);
    try samples_strategy.lowerSampleExtents(ctx);
    ctx.logInfoFmt("Lowered MP4 tracks and sample extents to IR", .{});
    return .ok;
}
