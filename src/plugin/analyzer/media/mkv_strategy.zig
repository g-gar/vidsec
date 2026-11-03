const std = @import("std");
const abi = @import("vidsec_abi");
const ir = @import("vidsec_ir");
const strategy_mod = @import("strategy.zig");
const MediaLoweringStrategy = strategy_mod.MediaLoweringStrategy;

fn nextTrackRow(ctx: abi.TaskContext) abi.SdkError!?abi.RowView_ABI {
    if (ctx.nextRow("mkv_tracks")) |maybe_row| {
        return maybe_row;
    } else |err| {
        if (err == error.NotFound) {
            if (ctx.nextRow("tracks")) |alt_row| {
                return alt_row;
            } else |alt_err| {
                if (alt_err == error.NotFound) return null;
                return alt_err;
            }
        }
        return err;
    }
}

/// Explicit implementation of `MediaLoweringStrategy` for Matroska/MKV track metadata.
pub const MkvMediaStrategy = struct {
    comptime {
        MediaLoweringStrategy.assertImplements(@This());
    }

    pub const name = "ebml";

    pub fn lowerTracks(ctx: abi.TaskContext, config_counter: *i64) abi.SdkError!void {
        while (try nextTrackRow(ctx)) |mkv_row| {
            const track_number = if (mkv_row.getField("track_number")) |v| v.asInt() orelse config_counter.* else config_counter.*;
            const codec_id = if (mkv_row.getField("codec_id")) |v| v.asText() orelse "unknown" else "unknown";
            const width = if (mkv_row.getField("width")) |v| v.asInt() orelse 0 else 0;
            const height = if (mkv_row.getField("height")) |v| v.asInt() orelse 0 else 0;

            try ir.emitIrCodecConfig(ctx, .{
                .config_id = config_counter.*,
                .track_id = track_number,
                .codec_tag = codec_id,
                .container_width = width,
                .container_height = height,
                .bitstream_width = width,
                .bitstream_height = height,
                .is_mismatch = false,
            });
            config_counter.* += 1;
        }
    }

    pub const strategy: MediaLoweringStrategy = .{
        .name = name,
        .lower_tracks = &lowerTracks,
    };
};

pub const lowerMkvTracks = MkvMediaStrategy.lowerTracks;
