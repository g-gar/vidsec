const std = @import("std");
const abi = @import("vidsec_abi");
const ebml = @import("vidsec_ebml");
const mkv = @import("vidsec_mkv");
const types = @import("types.zig");

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const MkvTriageEvaluation = struct {
    verdict: Verdict,
    critical_count: u32,
    warning_count: u32,
    flags_csv: []const u8,
};

/// Evaluates security policy over MKV inspection results.
pub fn evaluateMkvPolicy(
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

    var verdict: Verdict = .pass;
    if (critical_count > 0 or result.tracks.len == 0) {
        verdict = .drop;
    } else if (warning_count > 0 or result.unreferenced_cluster_slack > (64 * 1024)) {
        verdict = .flagged;
    }

    return .{
        .verdict = verdict,
        .critical_count = critical_count,
        .warning_count = warning_count,
        .flags_csv = fw.written(),
    };
}

/// Converts an `abi.BoundedStreamReader` into an `ebml.ByteSource`.
pub fn makeByteSource(stream: abi.BoundedStreamReader) ebml.ByteSource {
    const StreamContext = struct {
        reader: abi.BoundedStreamReader,

        fn readAt(ctx_ptr: *const anyopaque, buf: []u8, offset: u64) anyerror!usize {
            const self = @as(*const @This(), @ptrCast(@alignCast(ctx_ptr)));
            self.reader.readAt(offset, buf) catch return 0;
            return buf.len;
        }
    };

    const S = struct {
        var shared_ctx: StreamContext = undefined;
    };
    S.shared_ctx = .{ .reader = stream };

    return .{
        .ctx = @ptrCast(&S.shared_ctx),
        .read_at_fn = StreamContext.readAt,
        .file_size = stream.len(),
    };
}

pub const ProbeMkvInputs = struct {
    stream: abi.BoundedStreamReader,
    file_size: u64 = 0,
    emit_tracks: bool = false,
};

/// C-ABI task implementation for `triage/probe_mkv`.
pub fn runProbeMkv(ctx: abi.TaskContext, inputs: ProbeMkvInputs) abi.SdkError!abi.TaskStatus_ABI {
    const stream = inputs.stream;
    const emit_tracks = inputs.emit_tracks;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const byte_source = makeByteSource(stream);

    // 1. EBML Element parsing
    const ebml_parser = ebml.SafeEbmlParser.init(allocator, .{
        .recurse_clusters = false,
    });
    const ebml_result = ebml_parser.parse(byte_source) catch |err| {
        ctx.logError("Failed to parse EBML structure for MKV triage");
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .fatal_error,
        };
    };

    // 2. MKV Track and Segment inspection
    const inspector = mkv.MkvInspector.init(allocator);
    const mkv_result = inspector.inspect(byte_source, ebml_result.elements) catch |err| {
        ctx.logError("Failed to inspect MKV tracks and segments");
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .fatal_error,
        };
    };

    // 3. Security evaluation
    var flags_buf: [1024]u8 = undefined;
    const evaluation = evaluateMkvPolicy(mkv_result, &flags_buf);

    var video_count: i64 = 0;
    var audio_count: i64 = 0;
    var primary_video_codec: []const u8 = "none";
    var primary_video_w: i64 = 0;
    var primary_video_h: i64 = 0;

    for (mkv_result.tracks) |t| {
        if (t.isVideo()) {
            video_count += 1;
            if (video_count == 1) {
                primary_video_codec = t.codec_id;
                if (t.video) |v| {
                    primary_video_w = @intCast(v.pixel_width);
                    primary_video_h = @intCast(v.pixel_height);
                }
            }
        } else if (t.isAudio()) {
            audio_count += 1;
        }
    }

    const duration_sec = mkv_result.info.durationSeconds();

    // 4. Emit primary MKV triage row
    try ctx.emitRow("mkv_triage", &.{
        abi.NamedField_ABI.init("track_count", abi.Value_ABI.fromInt(@intCast(mkv_result.tracks.len))),
        abi.NamedField_ABI.init("video_track_count", abi.Value_ABI.fromInt(video_count)),
        abi.NamedField_ABI.init("audio_track_count", abi.Value_ABI.fromInt(audio_count)),
        abi.NamedField_ABI.init("duration_seconds", abi.Value_ABI.fromFloat(duration_sec)),
        abi.NamedField_ABI.init("muxing_app", abi.Value_ABI.fromText(mkv_result.info.muxing_app)),
        abi.NamedField_ABI.init("writing_app", abi.Value_ABI.fromText(mkv_result.info.writing_app)),
        abi.NamedField_ABI.init("primary_video_codec", abi.Value_ABI.fromText(primary_video_codec)),
        abi.NamedField_ABI.init("video_width", abi.Value_ABI.fromInt(primary_video_w)),
        abi.NamedField_ABI.init("video_height", abi.Value_ABI.fromInt(primary_video_h)),
        abi.NamedField_ABI.init("cluster_count", abi.Value_ABI.fromInt(@intCast(mkv_result.cluster_count))),
        abi.NamedField_ABI.init("total_cluster_bytes", abi.Value_ABI.fromInt(@intCast(mkv_result.total_cluster_bytes))),
        abi.NamedField_ABI.init("unreferenced_cluster_slack", abi.Value_ABI.fromInt(@intCast(mkv_result.unreferenced_cluster_slack))),
        abi.NamedField_ABI.init("verdict", abi.Value_ABI.fromInt(evaluation.verdict.toInt())),
        abi.NamedField_ABI.init("flags_csv", abi.Value_ABI.fromText(evaluation.flags_csv)),
    });

    // 5. Optionally emit tracks table
    if (emit_tracks) {
        for (mkv_result.tracks) |t| {
            var w: i64 = 0;
            var h: i64 = 0;
            var sf: f64 = 0.0;
            var ch: i64 = 0;

            if (t.video) |v| {
                w = @intCast(v.pixel_width);
                h = @intCast(v.pixel_height);
            }
            if (t.audio) |a| {
                sf = a.sampling_frequency;
                ch = @intCast(a.channels);
            }

            try ctx.emitRow("mkv_tracks", &.{
                abi.NamedField_ABI.init("track_number", abi.Value_ABI.fromInt(@intCast(t.track_number))),
                abi.NamedField_ABI.init("track_uid", abi.Value_ABI.fromInt(@intCast(t.track_uid))),
                abi.NamedField_ABI.init("track_type", abi.Value_ABI.fromText(t.track_type.asText())),
                abi.NamedField_ABI.init("codec_id", abi.Value_ABI.fromText(t.codec_id)),
                abi.NamedField_ABI.init("codec_name", abi.Value_ABI.fromText(t.codec_name)),
                abi.NamedField_ABI.init("width", abi.Value_ABI.fromInt(w)),
                abi.NamedField_ABI.init("height", abi.Value_ABI.fromInt(h)),
                abi.NamedField_ABI.init("sampling_frequency", abi.Value_ABI.fromFloat(sf)),
                abi.NamedField_ABI.init("channels", abi.Value_ABI.fromInt(ch)),
                abi.NamedField_ABI.init("default_duration_ns", abi.Value_ABI.fromInt(@intCast(t.default_duration_ns))),
            });
        }
    }

    if (evaluation.verdict == .pass) {
        ctx.logInfoFmt("Passed MKV triage: {d} tracks ({d} video, {d} audio), codec={s}, {d}x{d}, duration={d:.2}s", .{
            mkv_result.tracks.len,
            video_count,
            audio_count,
            primary_video_codec,
            primary_video_w,
            primary_video_h,
            mkv_result.info.durationSeconds(),
        });
    } else if (evaluation.verdict == .flagged) {
        ctx.logWarnFmt("MKV triage FLAGGED: {s}", .{evaluation.flags_csv});
    } else {
        ctx.logErrorFmt("MKV triage REJECTED/DROP: {s}", .{evaluation.flags_csv});
    }

    return .ok;
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

/// Modern pure Black Box task for Level 2 MKV semantic audit (`analyzer/probe_mkv`).
pub fn probeMkvTask(alloc: std.mem.Allocator, in: []const u8) !ProbeMkvOutput {
    const byte_source = ebml.ByteSource.fromSlice(in);
    const ebml_parser = ebml.SafeEbmlParser.init(alloc, .{});
    const parse_result = try ebml_parser.parse(byte_source);

    const inspector = mkv.MkvInspector.init(alloc);
    const mkv_result = try inspector.inspect(byte_source, parse_result.elements);

    const flags_buf = try alloc.alloc(u8, 1024);
    const evaluation = evaluateMkvPolicy(mkv_result, flags_buf);

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
