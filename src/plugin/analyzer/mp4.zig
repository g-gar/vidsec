const std = @import("std");
const abi = @import("vidsec_abi");
const isobmff = @import("vidsec_isobmff");
const mp4 = @import("vidsec_mp4");
const types = @import("types.zig");

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const Mp4TriageEvaluation = struct {
    verdict: Verdict,
    critical_count: u32,
    warning_count: u32,
    flags_csv: []const u8,
};

/// Evaluates MP4-specific security policies over inspection results.
pub fn evaluateMp4Policy(
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

    var verdict: Verdict = .pass;
    if (critical_count > 0) {
        verdict = .drop;
    } else if (warning_count > 0 or result.unreferenced_mdat_slack > (64 * 1024)) {
        verdict = .flagged;
    }

    return .{
        .verdict = verdict,
        .critical_count = critical_count,
        .warning_count = warning_count,
        .flags_csv = fw.written(),
    };
}

/// Adapter converting an `abi.BoundedStreamReader` into an `isobmff.ByteSource`.
pub fn makeByteSource(stream: abi.BoundedStreamReader) isobmff.ByteSource {
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

/// C-ABI task implementation for `triage/probe_mp4`.
pub fn runProbeMp4(ctx: abi.TaskContext) abi.SdkError!abi.TaskStatus_ABI {
    const stream = ctx.streamReader();
    const emit_tracks = try ctx.getParamBool("emit_tracks", false);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const byte_source = makeByteSource(stream);

    // 1. Box tree parsing
    const box_parser = isobmff.SafeBoxParser.init(allocator);
    const parse_result = box_parser.parse(byte_source) catch |err| {
        ctx.logError("Failed to parse ISOBMFF boxes for MP4 triage");
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .fatal_error,
        };
    };

    // 2. MP4-specific semantic inspection
    const inspector = mp4.Mp4Inspector.init(allocator);
    const mp4_result = inspector.inspect(byte_source, parse_result.boxes) catch |err| {
        ctx.logError("Failed to inspect MP4 tracks and descriptors");
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .fatal_error,
        };
    };

    // 3. Security evaluation
    var flags_buf: [1024]u8 = undefined;
    const evaluation = evaluateMp4Policy(mp4_result, &flags_buf);

    // Count video & audio tracks, locate primary video track properties
    var video_count: i64 = 0;
    var audio_count: i64 = 0;
    var primary_video_codec: [4]u8 = "none".*;
    var primary_video_w: i64 = 0;
    var primary_video_h: i64 = 0;

    for (mp4_result.tracks) |tr| {
        if (tr.isVideo()) {
            video_count += 1;
            if (video_count == 1) {
                primary_video_codec = tr.codec_fourcc.bytes;
                primary_video_w = @intCast(tr.width);
                primary_video_h = @intCast(tr.height);
            }
        } else if (tr.isAudio()) {
            audio_count += 1;
        }
    }

    var brand_buf: [4]u8 = "isom".*;
    if (mp4_result.ftyp) |f| {
        brand_buf = f.major_brand.bytes;
    }

    // 4. Emit primary MP4 triage row
    try ctx.emitRow("mp4_triage", &.{
        abi.NamedField_ABI.init("track_count", abi.Value_ABI.fromInt(@intCast(mp4_result.tracks.len))),
        abi.NamedField_ABI.init("video_track_count", abi.Value_ABI.fromInt(video_count)),
        abi.NamedField_ABI.init("audio_track_count", abi.Value_ABI.fromInt(audio_count)),
        abi.NamedField_ABI.init("major_brand", abi.Value_ABI.fromText(&brand_buf)),
        abi.NamedField_ABI.init("video_codec", abi.Value_ABI.fromText(&primary_video_codec)),
        abi.NamedField_ABI.init("video_width", abi.Value_ABI.fromInt(primary_video_w)),
        abi.NamedField_ABI.init("video_height", abi.Value_ABI.fromInt(primary_video_h)),
        abi.NamedField_ABI.init("total_samples", abi.Value_ABI.fromInt(@intCast(mp4_result.total_samples))),
        abi.NamedField_ABI.init("total_sample_bytes", abi.Value_ABI.fromInt(@intCast(mp4_result.total_sample_bytes))),
        abi.NamedField_ABI.init("unreferenced_mdat_slack", abi.Value_ABI.fromInt(@intCast(mp4_result.unreferenced_mdat_slack))),
        abi.NamedField_ABI.init("verdict", abi.Value_ABI.fromInt(evaluation.verdict.toInt())),
        abi.NamedField_ABI.init("flags_csv", abi.Value_ABI.fromText(evaluation.flags_csv)),
    });

    // 5. Optionally emit tracks table
    if (emit_tracks) {
        for (mp4_result.tracks) |tr| {
            var h_buf: [4]u8 = tr.handler_type.bytes;
            var c_buf: [4]u8 = tr.codec_fourcc.bytes;
            try ctx.emitRow("mp4_tracks", &.{
                abi.NamedField_ABI.init("track_id", abi.Value_ABI.fromInt(@intCast(tr.track_id))),
                abi.NamedField_ABI.init("handler_type", abi.Value_ABI.fromText(&h_buf)),
                abi.NamedField_ABI.init("codec_fourcc", abi.Value_ABI.fromText(&c_buf)),
                abi.NamedField_ABI.init("width", abi.Value_ABI.fromInt(@intCast(tr.width))),
                abi.NamedField_ABI.init("height", abi.Value_ABI.fromInt(@intCast(tr.height))),
                abi.NamedField_ABI.init("timescale", abi.Value_ABI.fromInt(@intCast(tr.timescale))),
                abi.NamedField_ABI.init("duration", abi.Value_ABI.fromInt(@intCast(tr.duration))),
                abi.NamedField_ABI.init("sample_count", abi.Value_ABI.fromInt(@intCast(tr.sample_count))),
                abi.NamedField_ABI.init("total_sample_bytes", abi.Value_ABI.fromInt(@intCast(tr.total_sample_bytes))),
            });
        }
    }

    if (evaluation.verdict == .pass) {
        ctx.logInfoFmt("Passed MP4 triage: {d} tracks ({d} video, {d} audio), brand={s}, unreferenced slack={d} bytes", .{
            mp4_result.tracks.len,
            video_count,
            audio_count,
            &brand_buf,
            mp4_result.unreferenced_mdat_slack,
        });
    } else if (evaluation.verdict == .flagged) {
        ctx.logWarnFmt("MP4 triage FLAGGED: {s}", .{evaluation.flags_csv});
    } else {
        ctx.logErrorFmt("MP4 triage REJECTED/DROP: {s}", .{evaluation.flags_csv});
    }

    return .ok;
}
