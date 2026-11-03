const std = @import("std");
const abi = @import("vidsec_abi");
const mkv_strategy = @import("mkv_strategy.zig");

pub const LowerMkvMediaInputs = struct {};

/// Lowers MKV tracks from `tracks` (or `mkv_tracks`) into `ir_codec_configs`.
pub fn runLowerMkvMedia(
    ctx: abi.TaskContext,
    _: LowerMkvMediaInputs,
) abi.SdkError!abi.TaskStatus_ABI {
    var config_counter: i64 = 1;
    try mkv_strategy.lowerMkvTracks(ctx, &config_counter);
    ctx.logInfoFmt("Lowered MKV tracks to IR", .{});
    return .ok;
}
