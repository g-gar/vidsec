const std = @import("std");
const abi = @import("vidsec_abi");
const strategy_mod = @import("strategy.zig");
const MediaLoweringStrategy = strategy_mod.MediaLoweringStrategy;

fn nextTrackRow(ctx: abi.TaskContext) abi.SdkError!?abi.RowView_ABI {
    if (ctx.nextRow("mp4_tracks")) |maybe_row| {
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

/// Explicit implementation of `MediaLoweringStrategy` for ISOBMFF/MP4 track metadata.
pub const Mp4MediaStrategy = struct {
    comptime {
        MediaLoweringStrategy.assertImplements(@This());
    }

    pub const name = "isobmff";

    pub fn lowerTracks(ctx: abi.TaskContext, config_counter: *i64) abi.SdkError!void {
        while (try nextTrackRow(ctx)) |mp4_row| {
            const track_id = if (mp4_row.getField("track_id")) |v| v.asInt() orelse config_counter.* else config_counter.*;
            const codec_fourcc = if (mp4_row.getField("codec_fourcc")) |v| v.asText() orelse "unknown" else "unknown";
            const width = if (mp4_row.getField("width")) |v| v.asInt() orelse 0 else 0;
            const height = if (mp4_row.getField("height")) |v| v.asInt() orelse 0 else 0;

            const fields = [_]abi.NamedField_ABI{
                abi.NamedField_ABI.init("config_id", abi.Value_ABI.fromInt(config_counter.*)),
                abi.NamedField_ABI.init("track_id", abi.Value_ABI.fromInt(track_id)),
                abi.NamedField_ABI.init("codec_tag", abi.Value_ABI.fromText(codec_fourcc)),
                abi.NamedField_ABI.init("container_width", abi.Value_ABI.fromInt(width)),
                abi.NamedField_ABI.init("container_height", abi.Value_ABI.fromInt(height)),
                abi.NamedField_ABI.init("bitstream_width", abi.Value_ABI.fromInt(width)),
                abi.NamedField_ABI.init("bitstream_height", abi.Value_ABI.fromInt(height)),
                abi.NamedField_ABI.init("is_mismatch", abi.Value_ABI.fromBool(false)),
            };

            try ctx.emitRow("ir_codec_configs", &fields);
            config_counter.* += 1;
        }
    }

    pub const strategy: MediaLoweringStrategy = .{
        .name = name,
        .lower_tracks = &lowerTracks,
    };
};

pub const lowerMp4Tracks = Mp4MediaStrategy.lowerTracks;
