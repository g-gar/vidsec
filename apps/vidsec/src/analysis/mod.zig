const std = @import("std");
const abi = @import("flowdata_abi");
const magic = @import("vidsec_magic");
const math = @import("vidsec_math");
const ir = @import("vidsec_ir");
const forensics = @import("vidsec_forensics");

pub const types = @import("types.zig");
pub const triage = @import("triage.zig");
pub const audit = @import("audit/mod.zig");
pub const lowering = @import("lowering/mod.zig");
pub const forensics_analysis = @import("forensics/mod.zig");

// Backward-compatible re-exports
pub const general = triage;
pub const isobmff_analyzer = audit.isobmff;
pub const mp4_analyzer = audit.mp4;
pub const ebml_analyzer = audit.ebml;
pub const mkv_analyzer = audit.mkv;
pub const riff_analyzer = audit.riff;
pub const ir_container = lowering.ir_container;
pub const ir_media = lowering.ir_media;
pub const container = lowering.container;
pub const media = lowering.media;
pub const topology = forensics_analysis.topology;
pub const entropy = forensics_analysis.entropy;
pub const inconsistencies = forensics_analysis.inconsistencies;

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const TriageFlag = triage.TriageFlag;
pub const TriageOptions = triage.TriageOptions;
pub const TriageResult = triage.TriageResult;
pub const analyzeSlice = triage.analyzeSlice;
pub const shannonEntropy = math.shannonEntropy;

pub const probeFileTask = triage.probeFile;
pub const probeIsobmffTask = audit.isobmff.auditIsobmff;
pub const probeMp4Task = audit.mp4.auditMp4;
pub const probeEbmlTask = audit.ebml.auditEbml;
pub const probeMkvTask = audit.mkv.auditMkv;
pub const probeRiffTask = audit.riff.auditRiff;

// --- C-ABI Bound Task Definitions for Forensics ---

pub const AnalyzeTopologyInputs = struct {
    stream: abi.BoundedStreamReader,
    file_size: u64 = 0,
    highest_root_end: u64 = 0,
    prev_verdict: ?i64 = null,
    allow_trailing_slack: bool = false,
    max_trailing_slack_bytes: u64 = 0,
};

pub fn runAnalyzeTopology(ctx: abi.TaskContext, inputs: AnalyzeTopologyInputs) abi.SdkError!abi.TaskStatus_ABI {
    var file_size: u64 = if (inputs.file_size > 0) inputs.file_size else inputs.stream.len();
    var highest_root_end: u64 = inputs.highest_root_end;

    if (highest_root_end == 0) {
        if (try ctx.nextRow("meta")) |meta_row| {
            if (meta_row.into(ir.ContainerMetadataRow)) |meta| {
                file_size = meta.file_size;
                highest_root_end = meta.highest_root_end;
            }
        }
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var regions_list = std.ArrayList(ir.IrRegionRow).empty;

    while (try ctx.nextRow("regions")) |reg_row| {
        const reg = reg_row.into(ir.IrRegionRow) orelse continue;
        if (reg.parent_region_id != null) continue; // Only inspect root-level regions
        try regions_list.append(allocator, reg);
    }

    const topo_output = forensics_analysis.analyzeTopology(
        allocator,
        file_size,
        highest_root_end,
        regions_list.items,
    ) catch return .fatal_error;

    for (topo_output.slacks) |slack| {
        try ir.emitIrUnreferencedSlack(ctx, slack);
    }

    for (topo_output.findings) |f| {
        try forensics.emitAuditFinding(ctx, f);
    }

    return .ok;
}

pub const ScanEntropyInputs = struct {
    stream: abi.BoundedStreamReader,
    file_size: u64 = 0,
    min_entropy: f64 = 7.2,
};

pub fn runScanEntropy(ctx: abi.TaskContext, inputs: ScanEntropyInputs) abi.SdkError!abi.TaskStatus_ABI {
    const min_entropy = inputs.min_entropy;
    const stream = inputs.stream;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var slacks_list = std.ArrayList(ir.IrUnreferencedSlackRow).empty;
    while (try ctx.nextRow("slack")) |row| {
        const slack = row.into(ir.IrUnreferencedSlackRow) orelse continue;
        try slacks_list.append(allocator, slack);
    }

    // Stream read backing for scanEntropy
    const file_size = if (inputs.file_size > 0) inputs.file_size else stream.len();
    const file_bytes = allocator.alloc(u8, @min(file_size, 64 * 1024 * 1024)) catch return .fatal_error;
    try stream.readAt(0, file_bytes);

    const findings = forensics_analysis.scanEntropy(
        allocator,
        file_bytes,
        slacks_list.items,
        .{ .min_entropy = min_entropy },
    ) catch return .fatal_error;

    for (findings) |f| {
        try forensics.emitAuditFinding(ctx, f);
    }

    return .ok;
}

pub const CheckInconsistenciesInputs = struct {
    stream: abi.BoundedStreamReader,
};

pub fn runCheckInconsistencies(ctx: abi.TaskContext, inputs: CheckInconsistenciesInputs) abi.SdkError!abi.TaskStatus_ABI {
    const file_size: u64 = inputs.stream.len();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var configs = std.ArrayList(ir.IrCodecConfigRow).empty;
    while (try ctx.nextRow("configs")) |row| {
        const config = row.into(ir.IrCodecConfigRow) orelse continue;
        try configs.append(allocator, config);
    }

    var extents = std.ArrayList(ir.IrSampleExtentRow).empty;
    while (try ctx.nextRow("extents")) |row| {
        const extent = row.into(ir.IrSampleExtentRow) orelse continue;
        try extents.append(allocator, extent);
    }

    const findings = forensics_analysis.checkInconsistencies(
        allocator,
        file_size,
        configs.items,
        extents.items,
    ) catch return .fatal_error;

    for (findings) |f| {
        try forensics.emitAuditFinding(ctx, f);
    }

    return .ok;
}

// --- C-ABI Bound Task Definitions for Media Lowering ---

fn nextTrackRow(ctx: abi.TaskContext, primary: [:0]const u8, alt: [:0]const u8) abi.SdkError!?abi.RowView_ABI {
    if (ctx.nextRow(primary)) |maybe_row| {
        return maybe_row;
    } else |err| {
        if (err == error.NotFound) {
            if (ctx.nextRow(alt)) |alt_row| {
                return alt_row;
            } else |alt_err| {
                if (alt_err == error.NotFound) return null;
                return alt_err;
            }
        }
        return err;
    }
}

fn nextSampleRow(ctx: abi.TaskContext) abi.SdkError!?abi.RowView_ABI {
    if (ctx.nextRow("samples")) |maybe_row| {
        return maybe_row;
    } else |err| {
        if (err == error.NotFound) {
            if (ctx.nextRow("sample_extents")) |alt_row| {
                return alt_row;
            } else |alt_err| {
                if (alt_err == error.NotFound) return null;
                return alt_err;
            }
        }
        return err;
    }
}

pub const LowerMp4MediaInputs = struct {};

pub fn runLowerMp4Media(ctx: abi.TaskContext, _: LowerMp4MediaInputs) abi.SdkError!abi.TaskStatus_ABI {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tracks = std.ArrayList(media.TrackInput).empty;
    var track_counter: i64 = 1;
    while (try nextTrackRow(ctx, "mp4_tracks", "tracks")) |row| {
        const track_id = if (row.getField("track_id")) |v| v.asInt() orelse track_counter else track_counter;
        const codec_fourcc = if (row.getField("codec_fourcc")) |v| v.asText() orelse "unknown" else "unknown";
        const width = if (row.getField("width")) |v| v.asInt() orelse 0 else 0;
        const height = if (row.getField("height")) |v| v.asInt() orelse 0 else 0;

        try tracks.append(allocator, .{
            .track_id = track_id,
            .codec_tag = codec_fourcc,
            .width = width,
            .height = height,
        });
        track_counter += 1;
    }

    var config_counter: i64 = 1;
    const configs = media.lowerMp4Tracks(allocator, tracks.items, &config_counter) catch return .fatal_error;
    for (configs) |cfg| {
        try ir.emitIrCodecConfig(ctx, cfg);
    }

    var samples = std.ArrayList(media.SampleInput).empty;
    var sample_idx: i64 = 1;
    while (try nextSampleRow(ctx)) |s_row| {
        const track_id = if (s_row.getField("track_id")) |v| v.asInt() orelse 1 else 1;
        const sample_index = if (s_row.getField("sample_index")) |v| v.asInt() orelse sample_idx else sample_idx;
        const source_tag = if (s_row.getField("source_tag")) |v| v.asText() orelse "mdat" else "mdat";
        const target_offset = if (s_row.getField("target_offset")) |v| v.asInt() orelse 0 else 0;
        const byte_size = if (s_row.getField("byte_size")) |v| v.asInt() orelse 0 else 0;

        try samples.append(allocator, .{
            .track_id = track_id,
            .sample_index = sample_index,
            .source_tag = source_tag,
            .target_offset = @intCast(@max(0, target_offset)),
            .byte_size = @intCast(@max(0, byte_size)),
        });
        sample_idx += 1;
    }

    var extent_counter: i64 = 1;
    const extents = media.lowerSampleExtents(allocator, samples.items, &extent_counter) catch return .fatal_error;
    for (extents) |ext| {
        try ir.emitIrSampleExtent(ctx, ext);
    }

    return .ok;
}

pub const LowerMkvMediaInputs = struct {};

pub fn runLowerMkvMedia(ctx: abi.TaskContext, _: LowerMkvMediaInputs) abi.SdkError!abi.TaskStatus_ABI {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tracks = std.ArrayList(media.TrackInput).empty;
    var track_counter: i64 = 1;
    while (try nextTrackRow(ctx, "mkv_tracks", "tracks")) |row| {
        const track_number = if (row.getField("track_number")) |v| v.asInt() orelse track_counter else track_counter;
        const codec_id = if (row.getField("codec_id")) |v| v.asText() orelse "unknown" else "unknown";
        const width = if (row.getField("width")) |v| v.asInt() orelse 0 else 0;
        const height = if (row.getField("height")) |v| v.asInt() orelse 0 else 0;

        try tracks.append(allocator, .{
            .track_id = track_number,
            .codec_tag = codec_id,
            .width = width,
            .height = height,
        });
        track_counter += 1;
    }

    var config_counter: i64 = 1;
    const configs = media.lowerMkvTracks(allocator, tracks.items, &config_counter) catch return .fatal_error;
    for (configs) |cfg| {
        try ir.emitIrCodecConfig(ctx, cfg);
    }

    return .ok;
}

pub const LowerMediaInputs = struct {
    detected_family: []const u8 = "",
};

pub fn runLowerMedia(ctx: abi.TaskContext, inputs: LowerMediaInputs) abi.SdkError!abi.TaskStatus_ABI {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_counter: i64 = 1;
    const family = inputs.detected_family;

    if (media.getMediaLoweringStrategy(family)) |strat| {
        var tracks = std.ArrayList(media.TrackInput).empty;
        const primary = if (std.mem.eql(u8, strat.name, "ebml")) "mkv_tracks" else "mp4_tracks";
        var track_counter: i64 = 1;
        while (try nextTrackRow(ctx, primary, "tracks")) |row| {
            const track_id = if (row.getField("track_id")) |v| v.asInt() orelse (if (row.getField("track_number")) |tn| tn.asInt() orelse track_counter else track_counter) else track_counter;
            const codec = if (row.getField("codec_fourcc")) |v| v.asText() orelse (if (row.getField("codec_id")) |ci| ci.asText() orelse "unknown" else "unknown") else "unknown";
            const width = if (row.getField("width")) |v| v.asInt() orelse 0 else 0;
            const height = if (row.getField("height")) |v| v.asInt() orelse 0 else 0;

            try tracks.append(allocator, .{
                .track_id = track_id,
                .codec_tag = codec,
                .width = width,
                .height = height,
            });
            track_counter += 1;
        }

        const configs = strat.lower_tracks(allocator, tracks.items, &config_counter) catch return .fatal_error;
        for (configs) |cfg| {
            try ir.emitIrCodecConfig(ctx, cfg);
        }
    } else {
        _ = try runLowerMp4Media(ctx, .{});
        _ = try runLowerMkvMedia(ctx, .{});
    }

    var samples = std.ArrayList(media.SampleInput).empty;
    var sample_idx: i64 = 1;
    while (try nextSampleRow(ctx)) |s_row| {
        const track_id = if (s_row.getField("track_id")) |v| v.asInt() orelse 1 else 1;
        const sample_index = if (s_row.getField("sample_index")) |v| v.asInt() orelse sample_idx else sample_idx;
        const source_tag = if (s_row.getField("source_tag")) |v| v.asText() orelse "mdat" else "mdat";
        const target_offset = if (s_row.getField("target_offset")) |v| v.asInt() orelse 0 else 0;
        const byte_size = if (s_row.getField("byte_size")) |v| v.asInt() orelse 0 else 0;

        try samples.append(allocator, .{
            .track_id = track_id,
            .sample_index = sample_index,
            .source_tag = source_tag,
            .target_offset = @intCast(@max(0, target_offset)),
            .byte_size = @intCast(@max(0, byte_size)),
        });
        sample_idx += 1;
    }

    if (samples.items.len > 0) {
        var extent_counter: i64 = 1;
        const extents = media.lowerSampleExtents(allocator, samples.items, &extent_counter) catch return .fatal_error;
        for (extents) |ext| {
            try ir.emitIrSampleExtent(ctx, ext);
        }
    }

    return .ok;
}

// --- C-ABI Bound Task Definitions for Container Lowering ---

fn nextRegionRow(ctx: abi.TaskContext, primary: [:0]const u8, alt: [:0]const u8) abi.SdkError!?abi.RowView_ABI {
    if (ctx.nextRow(primary)) |maybe_row| {
        return maybe_row;
    } else |err| {
        if (err == error.NotFound) {
            if (ctx.nextRow(alt)) |alt_row| {
                return alt_row;
            } else |alt_err| {
                if (alt_err == error.NotFound) return null;
                return alt_err;
            }
        }
        return err;
    }
}

pub const LowerIsobmffContainerInputs = struct {
    stream: abi.BoundedStreamReader,
    file_size: u64 = 0,
    true_magic_kind: i64 = 0,
    true_magic_name: []const u8 = "mp4",
};

pub fn runLowerIsobmffContainer(ctx: abi.TaskContext, inputs: LowerIsobmffContainerInputs) abi.SdkError!abi.TaskStatus_ABI {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file_size: i64 = if (inputs.file_size > 0) @intCast(inputs.file_size) else @intCast(inputs.stream.len());
    var regions_list = std.ArrayList(container.RegionInput).empty;

    while (try nextRegionRow(ctx, "boxes", "isobmff_boxes")) |box_row| {
        const box_id = if (box_row.getField("box_id")) |v| v.asInt() orelse 0 else 0;
        const maybe_parent = if (box_row.getField("parent_box_id")) |v| v.asInt() else null;
        const fourcc = if (box_row.getField("fourcc")) |v| v.asText() orelse "????" else "????";
        const role = if (box_row.getField("role")) |v| v.asText() orelse "unknown" else "unknown";
        const header_offset = if (box_row.getField("header_offset")) |v| v.asInt() orelse 0 else 0;
        const payload_offset = if (box_row.getField("payload_offset")) |v| v.asInt() orelse 0 else 0;
        const box_size = if (box_row.getField("box_size")) |v| v.asInt() orelse 0 else 0;

        try regions_list.append(allocator, .{
            .id = box_id,
            .parent_id = maybe_parent,
            .tag = fourcc,
            .role = role,
            .header_offset = header_offset,
            .payload_offset = payload_offset,
            .size = box_size,
        });
    }

    const output = container.lowerIsobmffContainer(
        allocator,
        file_size,
        inputs.true_magic_kind,
        inputs.true_magic_name,
        regions_list.items,
    ) catch return .fatal_error;

    for (output.regions) |reg| {
        try ir.emitIrRegion(ctx, reg);
    }
    for (output.overflow_findings) |f| {
        try forensics.emitAuditFinding(ctx, f);
    }
    try ir.emitContainerMetadata(ctx, output.metadata);

    return .ok;
}

pub const LowerEbmlContainerInputs = struct {
    stream: abi.BoundedStreamReader,
    file_size: u64 = 0,
    true_magic_kind: i64 = 0,
    true_magic_name: []const u8 = "mkv",
};

pub fn runLowerEbmlContainer(ctx: abi.TaskContext, inputs: LowerEbmlContainerInputs) abi.SdkError!abi.TaskStatus_ABI {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file_size: i64 = if (inputs.file_size > 0) @intCast(inputs.file_size) else @intCast(inputs.stream.len());
    var regions_list = std.ArrayList(container.RegionInput).empty;

    while (try nextRegionRow(ctx, "elements", "ebml_elements")) |elem_row| {
        const element_id = if (elem_row.getField("element_id")) |v| v.asInt() orelse 0 else 0;
        const maybe_parent = if (elem_row.getField("parent_element_id")) |v| v.asInt() else null;
        const ebml_id_hex = if (elem_row.getField("ebml_id_hex")) |v| v.asText() orelse "0x00" else "0x00";
        const role = if (elem_row.getField("role")) |v| v.asText() orelse "unknown" else "unknown";
        const header_offset = if (elem_row.getField("header_offset")) |v| v.asInt() orelse 0 else 0;
        const payload_offset = if (elem_row.getField("payload_offset")) |v| v.asInt() orelse 0 else 0;
        const total_size = if (elem_row.getField("total_size")) |v| v.asInt() orelse 0 else 0;

        try regions_list.append(allocator, .{
            .id = element_id,
            .parent_id = maybe_parent,
            .tag = ebml_id_hex,
            .role = role,
            .header_offset = header_offset,
            .payload_offset = payload_offset,
            .size = total_size,
        });
    }

    const output = container.lowerEbmlContainer(
        allocator,
        file_size,
        inputs.true_magic_kind,
        inputs.true_magic_name,
        regions_list.items,
    ) catch return .fatal_error;

    for (output.regions) |reg| {
        try ir.emitIrRegion(ctx, reg);
    }
    for (output.overflow_findings) |f| {
        try forensics.emitAuditFinding(ctx, f);
    }
    try ir.emitContainerMetadata(ctx, output.metadata);

    return .ok;
}

pub const LowerRiffContainerInputs = struct {
    stream: abi.BoundedStreamReader,
    file_size: u64 = 0,
    true_magic_kind: i64 = 0,
    true_magic_name: []const u8 = "avi",
};

pub fn runLowerRiffContainer(ctx: abi.TaskContext, inputs: LowerRiffContainerInputs) abi.SdkError!abi.TaskStatus_ABI {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file_size: i64 = if (inputs.file_size > 0) @intCast(inputs.file_size) else @intCast(inputs.stream.len());
    var regions_list = std.ArrayList(container.RegionInput).empty;

    while (try nextRegionRow(ctx, "chunks", "riff_chunks")) |chunk_row| {
        const chunk_id = if (chunk_row.getField("chunk_id")) |v| v.asInt() orelse 0 else 0;
        const maybe_parent = if (chunk_row.getField("parent_chunk_id")) |v| v.asInt() else null;
        const fourcc = if (chunk_row.getField("fourcc")) |v| v.asText() orelse "????" else "????";
        const role = if (chunk_row.getField("role")) |v| v.asText() orelse "unknown" else "unknown";
        const header_offset = if (chunk_row.getField("header_offset")) |v| v.asInt() orelse 0 else 0;
        const payload_offset = if (chunk_row.getField("payload_offset")) |v| v.asInt() orelse 0 else 0;
        const total_size = if (chunk_row.getField("total_size")) |v| v.asInt() orelse 0 else 0;

        try regions_list.append(allocator, .{
            .id = chunk_id,
            .parent_id = maybe_parent,
            .tag = fourcc,
            .role = role,
            .header_offset = header_offset,
            .payload_offset = payload_offset,
            .size = total_size,
        });
    }

    const output = container.lowerRiffContainer(
        allocator,
        file_size,
        inputs.true_magic_kind,
        inputs.true_magic_name,
        regions_list.items,
    ) catch return .fatal_error;

    for (output.regions) |reg| {
        try ir.emitIrRegion(ctx, reg);
    }
    for (output.overflow_findings) |f| {
        try forensics.emitAuditFinding(ctx, f);
    }
    try ir.emitContainerMetadata(ctx, output.metadata);

    return .ok;
}

pub const LowerContainerInputs = struct {
    stream: abi.BoundedStreamReader,
    file_size: u64 = 0,
    detected_family: []const u8 = "unknown",
    true_magic_kind: i64 = 0,
    true_magic_name: []const u8 = "unknown",
};

pub fn runLowerContainer(ctx: abi.TaskContext, inputs: LowerContainerInputs) abi.SdkError!abi.TaskStatus_ABI {
    var file_size: u64 = inputs.file_size;
    var detected_family: []const u8 = inputs.detected_family;
    var true_magic_kind: i64 = inputs.true_magic_kind;
    var true_magic_name: []const u8 = inputs.true_magic_name;

    if (true_magic_kind == 0 and std.mem.eql(u8, detected_family, "unknown")) {
        if (try nextRegionRow(ctx, "triage", "file_triage")) |triage_row| {
            if (triage_row.getField("file_size")) |v| {
                if (v.asInt()) |sz| file_size = @intCast(@max(0, sz));
            }
            if (triage_row.getField("true_magic_kind")) |v| {
                if (v.asInt()) |k| true_magic_kind = k;
            }
            if (triage_row.getField("true_magic_name")) |v| {
                if (v.asText()) |n| true_magic_name = n;
            }
            if (triage_row.getField("detected_family")) |v| {
                if (v.asText()) |f| detected_family = f;
            }
        }
    }

    if (std.mem.eql(u8, detected_family, "isobmff") or std.mem.eql(u8, detected_family, "mp4")) {
        return runLowerIsobmffContainer(ctx, .{
            .stream = inputs.stream,
            .file_size = file_size,
            .true_magic_kind = true_magic_kind,
            .true_magic_name = true_magic_name,
        });
    } else if (std.mem.eql(u8, detected_family, "ebml") or std.mem.eql(u8, detected_family, "mkv")) {
        return runLowerEbmlContainer(ctx, .{
            .stream = inputs.stream,
            .file_size = file_size,
            .true_magic_kind = true_magic_kind,
            .true_magic_name = true_magic_name,
        });
    } else if (std.mem.eql(u8, detected_family, "riff") or std.mem.eql(u8, detected_family, "avi")) {
        return runLowerRiffContainer(ctx, .{
            .stream = inputs.stream,
            .file_size = file_size,
            .true_magic_kind = true_magic_kind,
            .true_magic_name = true_magic_name,
        });
    } else {
        return runLowerIsobmffContainer(ctx, .{
            .stream = inputs.stream,
            .file_size = file_size,
            .true_magic_kind = true_magic_kind,
            .true_magic_name = true_magic_name,
        });
    }
}

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

pub const RecordFindingInputs = struct {
    rule_id: []const u8 = "UNKNOWN_RULE",
    severity: i64 = 1,
    message: ?[]const u8 = null,
    file_offset: i64 = 0,
    byte_length: i64 = 0,
};

pub fn runRecordFinding(ctx: abi.TaskContext, inputs: RecordFindingInputs) abi.SdkError!abi.TaskStatus_ABI {
    forensics.emitAuditFinding(ctx, .{
        .rule_id = inputs.rule_id,
        .severity = inputs.severity,
        .message = inputs.message,
        .file_offset = inputs.file_offset,
        .byte_length = inputs.byte_length,
        .end_offset = inputs.file_offset + inputs.byte_length,
    }) catch return .fatal_error;
    return .ok;
}

pub const tasks = [_]abi.TaskDescriptor_ABI{
    // Level 0: Universal Pre-Triage (Modern Black Box)
    abi.defineBlackBoxTask(.{
        .name = "probe_file",
        .description = "Level 0 lightweight multimedia triage: magic bytes, MIME, polyglot EOCD, mid-stream Shannon entropy",
        .run = &probeFileTask,
    }),

    // Level 1: Container Structural Audits (Modern Black Box)
    abi.defineBlackBoxTask(.{
        .name = "audit_isobmff",
        .description = "Level 1 structural auditing for ISOBMFF containers (MP4/MOV): box grammar, overflows, cycles, trailing slack",
        .run = &probeIsobmffTask,
    }),
    abi.defineBlackBoxTask(.{
        .name = "probe_isobmff",
        .description = "Alias for audit_isobmff",
        .run = &probeIsobmffTask,
    }),
    abi.defineBlackBoxTask(.{
        .name = "audit_ebml",
        .description = "Level 1 structural auditing for EBML containers (MKV/WebM): VINT encoding, element hierarchy, nesting bounds",
        .run = &probeEbmlTask,
    }),
    abi.defineBlackBoxTask(.{
        .name = "probe_ebml",
        .description = "Alias for audit_ebml",
        .run = &probeEbmlTask,
    }),
    abi.defineBlackBoxTask(.{
        .name = "audit_riff",
        .description = "Level 1 structural auditing for RIFF containers (AVI/WAV/WEBP): chunk headers, LIST nesting, word alignment",
        .run = &probeRiffTask,
    }),
    abi.defineBlackBoxTask(.{
        .name = "probe_riff",
        .description = "Alias for audit_riff",
        .run = &probeRiffTask,
    }),

    // Level 2: Format-Specific Semantic Audits (Modern Black Box)
    abi.defineBlackBoxTask(.{
        .name = "audit_mp4",
        .description = "Level 2 semantic auditing for MP4: track decoding, ftyp brands, avcC/esds codec configs, sample tables",
        .run = &probeMp4Task,
    }),
    abi.defineBlackBoxTask(.{
        .name = "probe_mp4",
        .description = "Alias for audit_mp4",
        .run = &probeMp4Task,
    }),
    abi.defineBlackBoxTask(.{
        .name = "audit_mkv",
        .description = "Level 2 semantic auditing for Matroska: track entries, codec parameters, SPS/PPS configs, cluster integrity",
        .run = &probeMkvTask,
    }),
    abi.defineBlackBoxTask(.{
        .name = "probe_mkv",
        .description = "Alias for audit_mkv",
        .run = &probeMkvTask,
    }),

    // Stage 2: Declarative Format-Specific IR Lowering
    abi.defineBoundTask(LowerIsobmffContainerInputs, .{
        .name = "lower_isobmff_container",
        .description = "Stage 2 IR Lowering: Normalizes ISOBMFF boxes into universal container_metadata and ir_regions",
        .output_fields = &LOWER_CONTAINER_OUTPUT_FIELDS,
        .run = &runLowerIsobmffContainer,
    }),
    abi.defineBoundTask(LowerIsobmffContainerInputs, .{
        .name = "lower_mp4_container",
        .description = "Stage 2 IR Lowering: Normalizes ISOBMFF boxes into universal container_metadata and ir_regions",
        .output_fields = &LOWER_CONTAINER_OUTPUT_FIELDS,
        .run = &runLowerIsobmffContainer,
    }),
    abi.defineBoundTask(LowerEbmlContainerInputs, .{
        .name = "lower_ebml_container",
        .description = "Stage 2 IR Lowering: Normalizes EBML elements into universal container_metadata and ir_regions",
        .output_fields = &LOWER_CONTAINER_OUTPUT_FIELDS,
        .run = &runLowerEbmlContainer,
    }),
    abi.defineBoundTask(LowerRiffContainerInputs, .{
        .name = "lower_riff_container",
        .description = "Stage 2 IR Lowering: Normalizes RIFF chunks into universal container_metadata and ir_regions",
        .output_fields = &LOWER_CONTAINER_OUTPUT_FIELDS,
        .run = &runLowerRiffContainer,
    }),
    abi.defineBoundTask(LowerMp4MediaInputs, .{
        .name = "lower_mp4_media",
        .description = "Stage 2 IR Lowering: Normalizes MP4 tracks and samples into ir_codec_configs and ir_sample_extents",
        .output_fields = &LOWER_MEDIA_OUTPUT_FIELDS,
        .run = &runLowerMp4Media,
    }),
    abi.defineBoundTask(LowerMkvMediaInputs, .{
        .name = "lower_mkv_media",
        .description = "Stage 2 IR Lowering: Normalizes MKV tracks into ir_codec_configs",
        .output_fields = &LOWER_MEDIA_OUTPUT_FIELDS,
        .run = &runLowerMkvMedia,
    }),

    // Stage 2: Universal IR Lowering (Aliases / Polyglot Fallbacks)
    abi.defineBoundTask(LowerContainerInputs, .{
        .name = "lower_container",
        .description = "Stage 2 IR Lowering: Normalizes format-specific container structures (ISOBMFF, EBML, RIFF) into universal container_metadata and ir_regions",
        .output_fields = &LOWER_CONTAINER_OUTPUT_FIELDS,
        .run = &runLowerContainer,
    }),
    abi.defineBoundTask(LowerMediaInputs, .{
        .name = "lower_media",
        .description = "Stage 2 IR Lowering: Normalizes format-specific track and codec tables into universal ir_codec_configs and ir_sample_extents",
        .output_fields = &LOWER_MEDIA_OUTPUT_FIELDS,
        .run = &runLowerMedia,
    }),

    // Universal Topology, Entropy & Inconsistencies
    abi.defineBoundTask(AnalyzeTopologyInputs, .{
        .name = "analyze_topology",
        .description = "Universal interval topology: unreferenced gaps, trailing overlays, and overlapping regions",
        .output_fields = &.{},
        .run = &runAnalyzeTopology,
    }),
    abi.defineBoundTask(ScanEntropyInputs, .{
        .name = "scan_entropy",
        .description = "Universal Shannon entropy scan over unreferenced slacks and gaps to detect hidden payloads",
        .output_fields = &.{},
        .run = &runScanEntropy,
    }),
    abi.defineBoundTask(CheckInconsistenciesInputs, .{
        .name = "check_inconsistencies",
        .description = "Universal container vs bitstream dimension discrepancies and sample extent boundaries",
        .output_fields = &.{},
        .run = &runCheckInconsistencies,
    }),
    abi.defineBoundTask(RecordFindingInputs, .{
        .name = "record_finding",
        .description = "Emits an audit finding record to audit_findings",
        .output_fields = &.{},
        .run = &runRecordFinding,
    }),
};

pub const manifest: abi.ModuleManifest_ABI = abi.defineManifest(
    "analyzer",
    .{ .major = 2, .minor = 0, .patch = 0 },
    &tasks,
);

// Exports the `flowdata_module_manifest` C-ABI symbol when compiled as a standalone `.so` plugin (`libanalyzer.so`)
comptime {
    if (@import("root") == @This()) {
        @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
    }
}
