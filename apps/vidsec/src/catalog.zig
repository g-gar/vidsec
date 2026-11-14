const abi = @import("flowdata_abi");
const container = @import("container.zig").VidsecPluginContainer;
const tasks_mod = @import("tasks/mod.zig");

const tasks = [_]abi.TaskDescriptor_ABI{
    // Stage 0: Pre-Triage
    container.defineTaskService(tasks_mod.check_file_size.Service, .{
        .name = "check_file_size",
        .description = "Validates stream length against configured minimum and maximum size limits.",
    }),
    container.defineTaskService(tasks_mod.detect_magic.Service, .{
        .name = "detect_magic",
        .description = "Identifies real format, MIME type, and container family from the leading header via tika.",
    }),
    container.defineTaskService(tasks_mod.check_extension.Service, .{
        .name = "check_extension",
        .description = "Validates whether the declared filename or extension matches the detected format.",
    }),
    container.defineTaskService(tasks_mod.scan_head_executables.Service, .{
        .name = "scan_head_executables",
        .description = "Scans the leading header window for primary or embedded MZ/ELF executable signatures.",
    }),
    container.defineTaskService(tasks_mod.scan_tail_archives.Service, .{
        .name = "scan_tail_archives",
        .description = "Scans the trailing stream window for appended ZIP EOCD, RAR, or 7z polyglot archives.",
    }),
    container.defineTaskService(tasks_mod.measure_mid_entropy.Service, .{
        .name = "measure_mid_entropy",
        .description = "Measures Shannon entropy over a bounded midpoint window of the stream.",
    }),

    // Remediation Subscribers
    container.defineTaskService(tasks_mod.apply_truncate.Service, .{
        .name = "apply_truncate",
        .description = "Subscribes to TruncateOrder and truncates the managed output artifact to new_size.",
    }),
    container.defineTaskService(tasks_mod.apply_zero_out.Service, .{
        .name = "apply_zero_out",
        .description = "Subscribes to ZeroOutOrder and overwrites the targeted byte range with 0x00.",
    }),

    // Stage 1: Format-Specific Container Parsing & Lowering to `media_ir`
    container.defineTaskService(tasks_mod.lower_mp4_container.Service, .{
        .name = "lower_mp4_container",
        .description = "Parses ISOBMFF/MP4 boxes in O(boxes) and lowers structure to media_ir regions and findings",
    }),
    container.defineTaskService(tasks_mod.lower_ebml_container.Service, .{
        .name = "lower_ebml_container",
        .description = "Parses EBML/Matroska elements in O(elements) and lowers structure to media_ir regions and findings",
    }),
    container.defineTaskService(tasks_mod.lower_riff_container.Service, .{
        .name = "lower_riff_container",
        .description = "Parses RIFF/AVI chunks in O(chunks) and lowers structure to media_ir regions and findings",
    }),

    // Stage 1a: Atomic Format-Specific & CVE Checks (Pre-Lowering)
    container.defineTaskService(tasks_mod.check_mp4_ftyp.Service, .{
        .name = "check_mp4_ftyp",
        .description = "Validates MP4 ftyp box presence, truncation, and recognized major brand",
    }),
    container.defineTaskService(tasks_mod.check_mp4_codecs.Service, .{
        .name = "check_mp4_codecs",
        .description = "Validates MP4 avcC (SPS/PPS overflows) and esds (TLV overflows) codec configs",
    }),
    container.defineTaskService(tasks_mod.check_mp4_tracks.Service, .{
        .name = "check_mp4_tracks",
        .description = "Validates MP4 trak hierarchy, stco/stsz sample bounds, and mdat slack",
    }),
    container.defineTaskService(tasks_mod.check_ebml_header.Service, .{
        .name = "check_ebml_header",
        .description = "Validates EBML header, Segment, doc_type, and VINT element size bounds",
    }),
    container.defineTaskService(tasks_mod.check_mkv_tracks.Service, .{
        .name = "check_mkv_tracks",
        .description = "Validates Matroska Tracks, track numbers, CodecID, and avcC CodecPrivate",
    }),
    container.defineTaskService(tasks_mod.check_riff_chunks.Service, .{
        .name = "check_riff_chunks",
        .description = "Validates RIFF form_type, chunk bounds, movi/JUNK totals, and trailing slack",
    }),
};

const manifest = abi.ModuleManifest_ABI{
    .abi_version = abi.FLOWDATA_ABI_VERSION,
    .module_name = "analyzer",
    .module_version = .{ .major = 2, .minor = 0, .patch = 0 },
    .tasks_ptr = &tasks,
    .tasks_len = tasks.len,
};

comptime {
    @export(&manifest, .{ .name = "flowdata_module_manifest", .linkage = .strong });
}
