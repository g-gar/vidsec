const std = @import("std");
const isobmff = @import("vidsec_isobmff");
const mp4 = @import("vidsec_mp4");
const types = @import("../types.zig");

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const Mp4TriageEvaluation = struct {
    verdict: Verdict,
    critical_count: u32,
    warning_count: u32,
    flags_csv: []const u8,
};

/// Evaluates MP4-specific security policies over inspection results.
pub fn evaluatePolicy(
    result: mp4.Mp4InspectionResult,
    flags_buf: []u8,
) Mp4TriageEvaluation {
    var fw = FixedBufWriter.init(flags_buf);
    var critical_count: u32 = 0;
    var warning_count: u32 = 0;
    var first_flag = true;

    for (result.issues) |issue| {
        const is_critical = switch (issue.code) {
            .track_id_zero,
            .track_id_duplicate,
            .avcc_sps_length_overflow,
            .avcc_pps_length_overflow,
            .esds_tlv_length_overflow,
            .stco_chunk_offset_out_of_bounds,
            .stsz_sample_extends_past_eof,
            => true,
            else => false,
        };

        if (is_critical) {
            critical_count += 1;
        } else {
            warning_count += 1;
        }

        if (!first_flag) {
            fw.writeAll(",") catch {};
        }
        fw.writeAll(issue.code.asText()) catch {};
        first_flag = false;
    }

    if (result.unreferenced_mdat_slack > 0) {
        if (!first_flag) fw.writeAll(",") catch {};
        fw.writeAll("MDAT_UNREFERENCED_PAYLOAD_DETECTED") catch {};
        first_flag = false;
        warning_count += 1;
    }

    if (result.tracks.len == 0) {
        if (!first_flag) fw.writeAll(",") catch {};
        fw.writeAll("NO_TRACKS_IN_MOOV") catch {};
        first_flag = false;
        warning_count += 1;
    }

    const verdict: Verdict = if (critical_count > 0)
        .drop
    else if (warning_count > 0)
        .flagged
    else
        .pass;

    return .{
        .verdict = verdict,
        .critical_count = critical_count,
        .warning_count = warning_count,
        .flags_csv = fw.written(),
    };
}

pub const ProbeMp4Output = struct {
    track_count: i64,
    video_track_count: i64,
    audio_track_count: i64,
    major_brand: []const u8,
    video_codec: []const u8,
    video_width: i64,
    video_height: i64,
    total_samples: i64,
    total_sample_bytes: i64,
    unreferenced_mdat_slack: i64,
    verdict: []const u8,
    flags_csv: []const u8,
};

/// Pure Black Box task for Level 2 MP4 semantic audit (`analyzer/probe_mp4`).
pub fn auditMp4(alloc: std.mem.Allocator, in: []const u8) !ProbeMp4Output {
    const byte_source = isobmff.ByteSource.fromSlice(in);
    const box_parser = isobmff.SafeBoxParser.init(alloc);
    const parse_result = try box_parser.parse(byte_source);

    const inspector = mp4.Mp4Inspector.init(alloc);
    const mp4_result = try inspector.inspect(byte_source, parse_result.boxes);

    const flags_buf = try alloc.alloc(u8, 1024);
    const evaluation = evaluatePolicy(mp4_result, flags_buf);

    var video_tracks: usize = 0;
    var audio_tracks: usize = 0;
    var primary_video_codec = try alloc.dupe(u8, "none");
    var primary_video_width: u32 = 0;
    var primary_video_height: u32 = 0;

    for (mp4_result.tracks) |t| {
        if (t.isVideo()) {
            video_tracks += 1;
            if (primary_video_width == 0) {
                primary_video_width = t.width;
                primary_video_height = t.height;
                primary_video_codec = try alloc.dupe(u8, &t.codec_fourcc.bytes);
            }
        } else if (t.isAudio()) {
            audio_tracks += 1;
        }
    }

    var brand = try alloc.dupe(u8, "none");
    if (mp4_result.ftyp) |ft| {
        brand = try alloc.dupe(u8, &ft.major_brand.bytes);
    }

    return .{
        .track_count = @intCast(mp4_result.tracks.len),
        .video_track_count = @intCast(video_tracks),
        .audio_track_count = @intCast(audio_tracks),
        .major_brand = brand,
        .video_codec = primary_video_codec,
        .video_width = @intCast(primary_video_width),
        .video_height = @intCast(primary_video_height),
        .total_samples = @intCast(mp4_result.total_samples),
        .total_sample_bytes = @intCast(mp4_result.total_sample_bytes),
        .unreferenced_mdat_slack = @intCast(mp4_result.unreferenced_mdat_slack),
        .verdict = evaluation.verdict.asText(),
        .flags_csv = evaluation.flags_csv,
    };
}
