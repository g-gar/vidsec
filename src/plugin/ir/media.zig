const std = @import("std");
const abi = @import("vidsec_abi");

fn tryNextRow(
    ctx: abi.TaskContext,
    primary: [:0]const u8,
    alt: [:0]const u8,
) abi.SdkError!?abi.RowView_ABI {
    if (ctx.nextRow(primary)) |maybe_row| {
        return maybe_row;
    } else |err| {
        if (err == error.NotFound) {
            if (ctx.nextRow(alt)) |maybe_alt_row| {
                return maybe_alt_row;
            } else |alt_err| {
                if (alt_err == error.NotFound) {
                    return null;
                }
                return alt_err;
            }
        }
        return err;
    }
}

/// Task `ir/lower_media`:
/// Normalizes format-specific track and codec tables (`mp4_tracks`, `mkv_tracks`)
/// into the unified `ir_codec_configs` and `ir_sample_extents`.
pub fn runLowerMedia(ctx: abi.TaskContext) abi.SdkError!abi.TaskStatus_ABI {
    var config_counter: i64 = 1;

    // 1. Lower MP4 tracks
    var has_mp4_tracks = false;
    while (try tryNextRow(ctx, "mp4_tracks", "tracks")) |mp4_row| {
        has_mp4_tracks = true;
        const track_id = if (mp4_row.getField("track_id")) |v| v.asInt() orelse config_counter else config_counter;
        const codec_fourcc = if (mp4_row.getField("codec_fourcc")) |v| v.asText() orelse "unknown" else "unknown";
        const width = if (mp4_row.getField("width")) |v| v.asInt() orelse 0 else 0;
        const height = if (mp4_row.getField("height")) |v| v.asInt() orelse 0 else 0;

        const fields = [_]abi.NamedField_ABI{
            abi.NamedField_ABI.init("config_id", abi.Value_ABI.fromInt(config_counter)),
            abi.NamedField_ABI.init("track_id", abi.Value_ABI.fromInt(track_id)),
            abi.NamedField_ABI.init("codec_tag", abi.Value_ABI.fromText(codec_fourcc)),
            abi.NamedField_ABI.init("container_width", abi.Value_ABI.fromInt(width)),
            abi.NamedField_ABI.init("container_height", abi.Value_ABI.fromInt(height)),
            abi.NamedField_ABI.init("bitstream_width", abi.Value_ABI.fromInt(width)),
            abi.NamedField_ABI.init("bitstream_height", abi.Value_ABI.fromInt(height)),
            abi.NamedField_ABI.init("is_mismatch", abi.Value_ABI.fromBool(false)),
        };

        try ctx.emitRow("ir_codec_configs", &fields);
        config_counter += 1;
    }

    // 2. Lower MKV tracks if no MP4 tracks were lowered
    if (!has_mp4_tracks) {
        while (try tryNextRow(ctx, "mkv_tracks", "tracks")) |mkv_row| {
            const track_number = if (mkv_row.getField("track_number")) |v| v.asInt() orelse config_counter else config_counter;
            const codec_id = if (mkv_row.getField("codec_id")) |v| v.asText() orelse "unknown" else "unknown";
            const width = if (mkv_row.getField("width")) |v| v.asInt() orelse 0 else 0;
            const height = if (mkv_row.getField("height")) |v| v.asInt() orelse 0 else 0;

            const fields = [_]abi.NamedField_ABI{
                abi.NamedField_ABI.init("config_id", abi.Value_ABI.fromInt(config_counter)),
                abi.NamedField_ABI.init("track_id", abi.Value_ABI.fromInt(track_number)),
                abi.NamedField_ABI.init("codec_tag", abi.Value_ABI.fromText(codec_id)),
                abi.NamedField_ABI.init("container_width", abi.Value_ABI.fromInt(width)),
                abi.NamedField_ABI.init("container_height", abi.Value_ABI.fromInt(height)),
                abi.NamedField_ABI.init("bitstream_width", abi.Value_ABI.fromInt(width)),
                abi.NamedField_ABI.init("bitstream_height", abi.Value_ABI.fromInt(height)),
                abi.NamedField_ABI.init("is_mismatch", abi.Value_ABI.fromBool(false)),
            };

            try ctx.emitRow("ir_codec_configs", &fields);
            config_counter += 1;
        }
    }

    // 3. Lower samples if a samples cursor is provided
    var extent_id: i64 = 1;
    while (try tryNextRow(ctx, "samples", "sample_extents")) |sample_row| {
        const track_id = if (sample_row.getField("track_id")) |v| v.asInt() orelse 1 else 1;
        const sample_index = if (sample_row.getField("sample_index")) |v| v.asInt() orelse extent_id else extent_id;
        const source_tag = if (sample_row.getField("source_tag")) |v| v.asText() orelse "mdat" else "mdat";
        const target_offset = if (sample_row.getField("target_offset")) |v| v.asInt() orelse 0 else 0;
        const byte_size = if (sample_row.getField("byte_size")) |v| v.asInt() orelse 0 else 0;
        const end_offset = target_offset + byte_size;

        const fields = [_]abi.NamedField_ABI{
            abi.NamedField_ABI.init("extent_id", abi.Value_ABI.fromInt(extent_id)),
            abi.NamedField_ABI.init("track_id", abi.Value_ABI.fromInt(track_id)),
            abi.NamedField_ABI.init("sample_index", abi.Value_ABI.fromInt(sample_index)),
            abi.NamedField_ABI.init("source_tag", abi.Value_ABI.fromText(source_tag)),
            abi.NamedField_ABI.init("target_offset", abi.Value_ABI.fromInt(target_offset)),
            abi.NamedField_ABI.init("byte_size", abi.Value_ABI.fromInt(byte_size)),
            abi.NamedField_ABI.init("end_offset", abi.Value_ABI.fromInt(end_offset)),
        };

        try ctx.emitRow("ir_sample_extents", &fields);
        extent_id += 1;
    }

    return .ok;
}
