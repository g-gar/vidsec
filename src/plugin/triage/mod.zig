const std = @import("std");
const abi = @import("vidsec_abi");
const magic = @import("vidsec_magic");
const math = @import("vidsec_math");

pub const types = @import("types.zig");
pub const general = @import("general.zig");
pub const checks = general;
pub const isobmff_triage = @import("isobmff.zig");
pub const mp4_triage = @import("mp4.zig");
pub const ebml_triage = @import("ebml.zig");
pub const mkv_triage = @import("mkv.zig");
pub const riff_triage = @import("riff.zig");

pub const shannonEntropy = math.shannonEntropy;
pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;
pub const TriageFlag = general.TriageFlag;
pub const TriageOptions = general.TriageOptions;
pub const TriageResult = general.TriageResult;
pub const analyzeStream = general.analyzeStream;
pub const analyzeSlice = general.analyzeSlice;
pub const runProbeIsobmff = isobmff_triage.runProbeIsobmff;
pub const runProbeMp4 = mp4_triage.runProbeMp4;
pub const runProbeEbml = ebml_triage.runProbeEbml;
pub const runProbeMkv = mkv_triage.runProbeMkv;
pub const runProbeRiff = riff_triage.runProbeRiff;

pub const PROBE_FILE_OUTPUT_FIELDS = [_][*:0]const u8{
    "file_size",
    "detected_family",
    "true_magic_kind",
    "true_magic_name",
    "exceeds_size_limit",
    "verdict",
    "identified_format",
    "mime_type",
    "extension_match",
    "mid_entropy",
    "head_size_read",
    "tail_size_read",
    "flags_csv",
    "suspicious_string",
    "zip_eocd_offset",
};

pub const PROBE_ISOBMFF_OUTPUT_FIELDS = [_][*:0]const u8{
    "box_count",
    "root_box_count",
    "max_depth",
    "mdat_count",
    "total_mdat_bytes",
    "trailing_slack_bytes",
    "verdict",
    "has_ftyp",
    "has_moov",
    "flags_csv",
};

pub const PROBE_MP4_OUTPUT_FIELDS = [_][*:0]const u8{
    "track_count",
    "video_track_count",
    "audio_track_count",
    "major_brand",
    "video_codec",
    "video_width",
    "video_height",
    "total_samples",
    "total_sample_bytes",
    "unreferenced_mdat_slack",
    "verdict",
    "flags_csv",
};

pub const PROBE_EBML_OUTPUT_FIELDS = [_][*:0]const u8{
    "element_count",
    "root_element_count",
    "max_depth",
    "cluster_count",
    "total_cluster_bytes",
    "trailing_slack_bytes",
    "doc_type",
    "doc_type_version",
    "verdict",
    "has_ebml_header",
    "has_segment",
    "flags_csv",
};

pub const PROBE_MKV_OUTPUT_FIELDS = [_][*:0]const u8{
    "track_count",
    "video_track_count",
    "audio_track_count",
    "duration_seconds",
    "muxing_app",
    "writing_app",
    "primary_video_codec",
    "video_width",
    "video_height",
    "cluster_count",
    "total_cluster_bytes",
    "unreferenced_cluster_slack",
    "verdict",
    "flags_csv",
};

pub const PROBE_RIFF_OUTPUT_FIELDS = [_][*:0]const u8{
    "chunk_count",
    "root_chunk_count",
    "max_depth",
    "form_type",
    "root_size",
    "movi_bytes",
    "junk_bytes",
    "trailing_slack_bytes",
    "verdict",
    "flags_csv",
};

/// C-ABI task implementation for `triage/probe_file`.
pub fn runProbeFile(ctx: abi.TaskContext) abi.SdkError!abi.TaskStatus_ABI {
    const max_mb_raw = try ctx.getParamInt("max_file_size_mb", @intCast(checks.DEFAULT_MAX_FILE_SIZE_MB));
    const max_mb: u64 = if (max_mb_raw > 0) @intCast(max_mb_raw) else checks.DEFAULT_MAX_FILE_SIZE_MB;
    const min_bytes_raw = try ctx.getParamInt("min_file_size_bytes", @intCast(checks.DEFAULT_MIN_FILE_SIZE));
    const min_bytes: u64 = if (min_bytes_raw >= 0) @intCast(min_bytes_raw) else 0;
    const min_entropy = try ctx.getParamFloat("min_mid_entropy", checks.DEFAULT_MIN_MID_ENTROPY);
    const strict_ext = try ctx.getParamBool("strict_extension", true);
    const file_path = try ctx.getParamText("file_path", "");
    const expected_ext = try ctx.getParamText("expected_extension", "");

    const opts = TriageOptions{
        .file_path = file_path,
        .expected_extension = expected_ext,
        .min_file_size_bytes = min_bytes,
        .max_file_size_bytes = max_mb *| (1024 * 1024),
        .min_mid_entropy = min_entropy,
        .strict_extension = strict_ext,
    };

    const res = try analyzeStream(ctx.streamReader(), opts);

    var flags_buf: [512]u8 = undefined;
    const flags_csv = res.formatFlagsCsv(&flags_buf);

    const suspicious_val = if (res.first_suspicious_string.len > 0)
        abi.Value_ABI.fromText(res.first_suspicious_string)
    else
        abi.Value_ABI.nullVal();

    const zip_eocd_val = if (res.zip_eocd_offset) |off|
        abi.Value_ABI.fromInt(@intCast(off))
    else
        abi.Value_ABI.nullVal();

    try ctx.emitRow(null, &.{
        abi.NamedField_ABI.init("file_size", abi.Value_ABI.fromInt(@intCast(res.file_size))),
        abi.NamedField_ABI.init("detected_family", abi.Value_ABI.fromText(res.detected_family)),
        abi.NamedField_ABI.init("true_magic_kind", abi.Value_ABI.fromInt(res.true_magic_kind)),
        abi.NamedField_ABI.init("true_magic_name", abi.Value_ABI.fromText(res.true_magic_name)),
        abi.NamedField_ABI.init("exceeds_size_limit", abi.Value_ABI.fromBool(res.exceeds_size_limit)),
        abi.NamedField_ABI.init("verdict", abi.Value_ABI.fromInt(res.verdict.toInt())),
        abi.NamedField_ABI.init("identified_format", abi.Value_ABI.fromText(res.identified_format)),
        abi.NamedField_ABI.init("mime_type", abi.Value_ABI.fromText(res.magic_info.mime_type)),
        abi.NamedField_ABI.init("extension_match", abi.Value_ABI.fromBool(res.extension_match)),
        abi.NamedField_ABI.init("mid_entropy", abi.Value_ABI.fromFloat(res.mid_entropy)),
        abi.NamedField_ABI.init("head_size_read", abi.Value_ABI.fromInt(@intCast(res.head_size_read))),
        abi.NamedField_ABI.init("tail_size_read", abi.Value_ABI.fromInt(@intCast(res.tail_size_read))),
        abi.NamedField_ABI.init("flags_csv", abi.Value_ABI.fromText(flags_csv)),
        abi.NamedField_ABI.init("suspicious_string", suspicious_val),
        abi.NamedField_ABI.init("zip_eocd_offset", zip_eocd_val),
    });

    if (res.verdict == .pass) {
        ctx.logInfo("triage/probe_file: PASS");
    } else if (res.verdict == .flagged) {
        ctx.logWarn(flags_csv);
    } else {
        ctx.logError(flags_csv);
    }

    return .ok;
}

pub const tasks = [_]abi.TaskDescriptor_ABI{
    abi.defineTask(.{
        .name = "probe_file",
        .description = "Stage 0 lightweight video triaging: size bounds, magic vs extension, polyglot tail EOCD, mid-stream Shannon entropy, and suspicious string scan",
        .output_fields = &PROBE_FILE_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeFile,
    }),
    abi.defineTask(.{
        .name = "probe_isobmff",
        .description = "Stage 1 native structural triaging for ISOBMFF containers (MP4/MOV): validates box grammar, detects overflows, cycles, trailing slack, and maps box hierarchy",
        .output_fields = &PROBE_ISOBMFF_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeIsobmff,
    }),
    abi.defineTask(.{
        .name = "probe_mp4",
        .description = "Stage 1 native semantic triaging for MP4 files: decodes tracks, validates ftyp brands, inspects avcC/esds codec configs, sample tables, and unreferenced mdat slack",
        .output_fields = &PROBE_MP4_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeMp4,
    }),
    abi.defineTask(.{
        .name = "probe_ebml",
        .description = "Stage 1 native structural triaging for EBML containers (MKV/WebM): validates VINT encoding, element hierarchy, nesting bounds, and doctype metadata",
        .output_fields = &PROBE_EBML_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeEbml,
    }),
    abi.defineTask(.{
        .name = "probe_mkv",
        .description = "Stage 1 native semantic triaging for Matroska files: inspects track entries, video/audio codec parameters, SPS/PPS configs, and cluster integrity",
        .output_fields = &PROBE_MKV_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeMkv,
    }),
    abi.defineTask(.{
        .name = "probe_riff",
        .description = "Stage 1 native structural triaging for RIFF containers (AVI/WAV/WEBP): validates RIFF chunk header, LIST nesting, word-padding alignment, and slack",
        .output_fields = &PROBE_RIFF_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeRiff,
    }),
};

pub const manifest: abi.ModuleManifest_ABI = abi.defineManifest(
    "triage",
    .{ .major = 2, .minor = 0, .patch = 0 },
    &tasks,
);

// Exports the `vidsec_module_manifest` C-ABI symbol when compiled as a standalone `.so` plugin
// (`libtriage.so`), while avoiding symbol collisions when imported alongside other plugins into `src/root.zig`.
comptime {
    if (@import("root") == @This()) {
        @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
    }
}


