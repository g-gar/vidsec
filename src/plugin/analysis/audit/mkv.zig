const std = @import("std");
const ebml = @import("vidsec_ebml");
const mkv = @import("vidsec_mkv");
const types = @import("../types.zig");

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const MkvTriageEvaluation = struct {
    verdict: Verdict,
    critical_count: u32,
    warning_count: u32,
    flags_csv: []const u8,
};

/// Evaluates Matroska-specific security policies over inspection results.
pub fn evaluatePolicy(
    result: mkv.MkvInspectionResult,
    flags_buf: []u8,
) MkvTriageEvaluation {
    var fw = FixedBufWriter.init(flags_buf);
    var critical_count: u32 = 0;
    var warning_count: u32 = 0;
    var first_flag = true;

    for (result.issues) |issue| {
        const is_critical = switch (issue.code) {
            .track_number_zero,
            .track_number_duplicate,
            .avcc_sps_length_overflow,
            .avcc_pps_length_overflow,
            .segment_missing_tracks,
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

    if (result.unreferenced_cluster_slack > 0) {
        if (!first_flag) fw.writeAll(",") catch {};
        fw.writeAll("CLUSTER_UNREFERENCED_PAYLOAD_DETECTED") catch {};
        first_flag = false;
        warning_count += 1;
    }

    if (result.tracks.len == 0) {
        if (!first_flag) fw.writeAll(",") catch {};
        fw.writeAll("NO_TRACKS_IN_SEGMENT") catch {};
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

pub const ProbeMkvOutput = struct {
    track_count: i64,
    video_track_count: i64,
    audio_track_count: i64,
    video_codec_id: []const u8,
    video_width: i64,
    video_height: i64,
    duration_seconds: f64,
    cluster_count: i64,
    unreferenced_cluster_slack: i64,
    verdict: []const u8,
    flags_csv: []const u8,
};

/// Pure Black Box task for Level 2 MKV semantic audit (`analyzer/probe_mkv`).
pub fn auditMkv(alloc: std.mem.Allocator, in: []const u8) !ProbeMkvOutput {
    const byte_source = ebml.ByteSource.fromSlice(in);
    const ebml_parser = ebml.SafeEbmlParser.init(alloc, .{});
    const parse_result = try ebml_parser.parse(byte_source);

    const inspector = mkv.MkvInspector.init(alloc);
    const mkv_result = try inspector.inspect(byte_source, parse_result.elements);

    const flags_buf = try alloc.alloc(u8, 1024);
    const evaluation = evaluatePolicy(mkv_result, flags_buf);

    var video_count: i64 = 0;
    var audio_count: i64 = 0;
    var primary_video_codec = try alloc.dupe(u8, "none");
    var primary_video_w: i64 = 0;
    var primary_video_h: i64 = 0;

    for (mkv_result.tracks) |t| {
        if (t.isVideo()) {
            video_count += 1;
            if (video_count == 1) {
                primary_video_codec = try alloc.dupe(u8, t.codec_id);
                if (t.video) |v| {
                    primary_video_w = @intCast(v.pixel_width);
                    primary_video_h = @intCast(v.pixel_height);
                }
            }
        } else if (t.isAudio()) {
            audio_count += 1;
        }
    }

    return .{
        .track_count = @intCast(mkv_result.tracks.len),
        .video_track_count = video_count,
        .audio_track_count = audio_count,
        .video_codec_id = primary_video_codec,
        .video_width = primary_video_w,
        .video_height = primary_video_h,
        .duration_seconds = mkv_result.info.durationSeconds(),
        .cluster_count = @intCast(mkv_result.cluster_count),
        .unreferenced_cluster_slack = @intCast(mkv_result.unreferenced_cluster_slack),
        .verdict = evaluation.verdict.asText(),
        .flags_csv = evaluation.flags_csv,
    };
}
