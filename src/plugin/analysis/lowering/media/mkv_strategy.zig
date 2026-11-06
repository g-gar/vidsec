const std = @import("std");
const ir = @import("vidsec_ir");
const strategy_mod = @import("strategy.zig");
const MediaLoweringStrategy = strategy_mod.MediaLoweringStrategy;
const TrackInput = strategy_mod.TrackInput;

/// Explicit implementation of `MediaLoweringStrategy` for Matroska/MKV track metadata.
pub const MkvMediaStrategy = struct {
    comptime {
        MediaLoweringStrategy.assertImplements(@This());
    }

    pub const name = "ebml";

    pub fn lowerTracks(
        allocator: std.mem.Allocator,
        tracks: []const TrackInput,
        config_counter: *i64,
    ) anyerror![]ir.IrCodecConfigRow {
        var list = std.ArrayList(ir.IrCodecConfigRow).empty;
        errdefer list.deinit(allocator);

        for (tracks) |t| {
            const b_w = t.bitstream_width orelse t.width;
            const b_h = t.bitstream_height orelse t.height;
            const is_mismatch = (t.width != 0 and b_w != 0 and t.width != b_w) or
                (t.height != 0 and b_h != 0 and t.height != b_h);

            try list.append(allocator, .{
                .config_id = config_counter.*,
                .track_id = t.track_id,
                .codec_tag = t.codec_tag,
                .container_width = t.width,
                .container_height = t.height,
                .bitstream_width = b_w,
                .bitstream_height = b_h,
                .is_mismatch = is_mismatch,
            });
            config_counter.* += 1;
        }

        return try list.toOwnedSlice(allocator);
    }

    pub const strategy: MediaLoweringStrategy = .{
        .name = name,
        .lower_tracks = &lowerTracks,
    };
};

pub const lowerMkvTracks = MkvMediaStrategy.lowerTracks;
