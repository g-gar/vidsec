const std = @import("std");
const abi = @import("vidsec_abi");
const magic = @import("vidsec_magic");
const math = @import("vidsec_math");
const ir = @import("vidsec_ir");
const forensics = @import("vidsec_forensics");

pub const types = @import("types.zig");
pub const general = @import("general.zig");
pub const isobmff_analyzer = @import("isobmff.zig");
pub const mp4_analyzer = @import("mp4.zig");
pub const ebml_analyzer = @import("ebml.zig");
pub const mkv_analyzer = @import("mkv.zig");
pub const riff_analyzer = @import("riff.zig");
pub const ir_container = @import("ir_container.zig");
pub const ir_media = @import("ir_media.zig");
pub const topology = @import("topology.zig");
pub const entropy = @import("entropy.zig");
pub const inconsistencies = @import("inconsistencies.zig");

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const TriageFlag = general.TriageFlag;
pub const TriageOptions = general.TriageOptions;
pub const TriageResult = general.TriageResult;
pub const analyzeStream = general.analyzeStream;
pub const analyzeSlice = general.analyzeSlice;
pub const shannonEntropy = math.shannonEntropy;

pub const runProbeFile = general.runProbeFile;
pub const runProbeIsobmff = isobmff_analyzer.runProbeIsobmff;
pub const runProbeMp4 = mp4_analyzer.runProbeMp4;
pub const runProbeEbml = ebml_analyzer.runProbeEbml;
pub const runProbeMkv = mkv_analyzer.runProbeMkv;
pub const runProbeRiff = riff_analyzer.runProbeRiff;
pub const runLowerContainer = ir_container.runLowerContainer;
pub const runLowerMedia = ir_media.runLowerMedia;
pub const runAnalyzeTopology = topology.runAnalyzeTopology;
pub const runScanEntropy = entropy.runScanEntropy;
pub const runCheckInconsistencies = inconsistencies.runCheckInconsistencies;

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
    "doc_type",
    "doc_type_version",
    "has_ebml_header",
    "has_segment",
    "cluster_count",
    "total_cluster_bytes",
    "trailing_slack_bytes",
    "verdict",
    "flags_csv",
};

pub const PROBE_MKV_OUTPUT_FIELDS = [_][*:0]const u8{
    "track_count",
    "video_track_count",
    "audio_track_count",
    "video_codec_id",
    "video_width",
    "video_height",
    "duration_seconds",
    "cluster_count",
    "unreferenced_cluster_slack",
    "verdict",
    "flags_csv",
};

pub const PROBE_RIFF_OUTPUT_FIELDS = [_][*:0]const u8{
    "chunk_count",
    "form_type",
    "root_size",
    "movi_bytes",
    "junk_bytes",
    "trailing_slack_bytes",
    "verdict",
    "flags_csv",
};

pub const LOWER_CONTAINER_OUTPUT_FIELDS = [_][*:0]const u8{
    "region_id",
    "parent_region_id",
    "tag_name",
    "role",
    "header_offset",
    "payload_offset",
    "effective_end_offset",
    "is_truncated_or_overflow",
};

pub const LOWER_MEDIA_OUTPUT_FIELDS = [_][*:0]const u8{
    "config_id",
    "track_id",
    "codec_tag",
    "container_width",
    "container_height",
    "bitstream_width",
    "bitstream_height",
    "is_mismatch",
};

pub const tasks = [_]abi.TaskDescriptor_ABI{
    // Level 0: Universal Pre-Triage
    abi.defineTask(.{
        .name = "probe_file",
        .description = "Level 0 lightweight multimedia triage: magic bytes, MIME, polyglot EOCD, mid-stream Shannon entropy",
        .output_fields = &PROBE_FILE_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeFile,
    }),

    // Level 1: Container Structural Audits (with aliases for backward compatibility)
    abi.defineTask(.{
        .name = "audit_isobmff",
        .description = "Level 1 structural auditing for ISOBMFF containers (MP4/MOV): box grammar, overflows, cycles, trailing slack",
        .output_fields = &PROBE_ISOBMFF_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeIsobmff,
    }),
    abi.defineTask(.{
        .name = "probe_isobmff",
        .description = "Alias for audit_isobmff",
        .output_fields = &PROBE_ISOBMFF_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeIsobmff,
    }),
    abi.defineTask(.{
        .name = "audit_ebml",
        .description = "Level 1 structural auditing for EBML containers (MKV/WebM): VINT encoding, element hierarchy, nesting bounds",
        .output_fields = &PROBE_EBML_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeEbml,
    }),
    abi.defineTask(.{
        .name = "probe_ebml",
        .description = "Alias for audit_ebml",
        .output_fields = &PROBE_EBML_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeEbml,
    }),
    abi.defineTask(.{
        .name = "audit_riff",
        .description = "Level 1 structural auditing for RIFF containers (AVI/WAV/WEBP): chunk headers, LIST nesting, word alignment",
        .output_fields = &PROBE_RIFF_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeRiff,
    }),
    abi.defineTask(.{
        .name = "probe_riff",
        .description = "Alias for audit_riff",
        .output_fields = &PROBE_RIFF_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeRiff,
    }),

    // Level 2: Format-Specific Semantic Audits
    abi.defineTask(.{
        .name = "audit_mp4",
        .description = "Level 2 semantic auditing for MP4: track decoding, ftyp brands, avcC/esds codec configs, sample tables",
        .output_fields = &PROBE_MP4_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeMp4,
    }),
    abi.defineTask(.{
        .name = "probe_mp4",
        .description = "Alias for audit_mp4",
        .output_fields = &PROBE_MP4_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeMp4,
    }),
    abi.defineTask(.{
        .name = "audit_mkv",
        .description = "Level 2 semantic auditing for Matroska: track entries, codec parameters, SPS/PPS configs, cluster integrity",
        .output_fields = &PROBE_MKV_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeMkv,
    }),
    abi.defineTask(.{
        .name = "probe_mkv",
        .description = "Alias for audit_mkv",
        .output_fields = &PROBE_MKV_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runProbeMkv,
    }),

    // Stage 2: Universal IR Lowering
    abi.defineTask(.{
        .name = "lower_container",
        .description = "Stage 2 IR Lowering: Normalizes format-specific container structures (ISOBMFF, EBML, RIFF) into universal container_metadata and ir_regions",
        .output_fields = &LOWER_CONTAINER_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runLowerContainer,
    }),
    abi.defineTask(.{
        .name = "lower_media",
        .description = "Stage 2 IR Lowering: Normalizes format-specific track and codec tables into universal ir_codec_configs and ir_sample_extents",
        .output_fields = &LOWER_MEDIA_OUTPUT_FIELDS,
        .required_params = &.{},
        .run = &runLowerMedia,
    }),

    // Universal Topology, Entropy & Inconsistencies
    abi.defineTask(.{
        .name = "analyze_topology",
        .description = "Universal interval topology: unreferenced gaps, trailing overlays, and overlapping regions",
        .output_fields = &.{},
        .required_params = &.{},
        .run = &runAnalyzeTopology,
    }),
    abi.defineTask(.{
        .name = "scan_entropy",
        .description = "Universal Shannon entropy scan over unreferenced slacks and gaps to detect hidden payloads",
        .output_fields = &.{},
        .required_params = &.{},
        .run = &runScanEntropy,
    }),
    abi.defineTask(.{
        .name = "check_inconsistencies",
        .description = "Universal container vs bitstream dimension discrepancies and sample extent boundaries",
        .output_fields = &.{},
        .required_params = &.{},
        .run = &runCheckInconsistencies,
    }),
};

pub const manifest: abi.ModuleManifest_ABI = abi.defineManifest(
    "analyzer",
    .{ .major = 2, .minor = 0, .patch = 0 },
    &tasks,
);

// Exports the `vidsec_module_manifest` C-ABI symbol when compiled as a standalone `.so` plugin (`libanalyzer.so`)
comptime {
    if (@import("root") == @This()) {
        @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
    }
}
