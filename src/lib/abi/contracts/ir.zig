const std = @import("std");
const Allocator = std.mem.Allocator;
const triage = @import("triage.zig");

pub const MagicKind = triage.MagicKind;

/// Normalized container format code for `container_metadata.detected_format`.
pub const ContainerFormat = enum(i64) {
    unknown = 0,
    isobmff = 1,
    ebml = 2,
    riff = 3,

    pub fn toInt(self: ContainerFormat) i64 {
        return @intFromEnum(self);
    }
};

/// Closed set of universal region roles across `ISOBMFF`, `EBML`, and `RIFF` (`ir_regions.role`).
pub const RegionRole = enum {
    container,
    media_data,
    padding,
    sample_table,
    codec_config,
    metadata,
    attachment,
    external_ref,
    unknown,

    pub fn asText(self: RegionRole) []const u8 {
        return switch (self) {
            .container => "container",
            .media_data => "media_data",
            .padding => "padding",
            .sample_table => "sample_table",
            .codec_config => "codec_config",
            .metadata => "metadata",
            .attachment => "attachment",
            .external_ref => "external_ref",
            .unknown => "unknown",
        };
    }
};

/// Strongly-typed row for `ir_core.container_metadata` (`configs/schemas.yaml`).
pub const ContainerMetadataRow = struct {
    file_size: u64,
    detected_format: i64 = 0,
    true_magic: i64 = 0,
    true_magic_name: []const u8 = "unknown",
    highest_root_end: u64 = 0,
};

/// Strongly-typed row for `ir_core.ir_regions` (`configs/schemas.yaml`).
pub const IrRegionRow = struct {
    region_id: i64,
    parent_region_id: ?i64 = null,
    tag_name: []const u8,
    role: []const u8 = "unknown",
    header_offset: u64,
    payload_offset: u64,
    effective_end_offset: u64,
    is_truncated_or_overflow: bool = false,
};

/// Strongly-typed row for `ir_deep.ir_sample_extents` (`configs/schemas.yaml`).
pub const IrSampleExtentRow = struct {
    extent_id: i64,
    track_id: i64,
    sample_index: i64,
    source_tag: []const u8,
    target_offset: u64,
    byte_size: u64,
    end_offset: u64,
};

/// Strongly-typed row for `ir_deep.ir_unreferenced_slack` (`configs/schemas.yaml`).
pub const IrUnreferencedSlackRow = struct {
    slack_id: i64,
    region_tag: []const u8,
    file_offset: u64,
    byte_length: u64,
};

/// Strongly-typed row for `ir_deep.ir_codec_configs` (`configs/schemas.yaml`).
pub const IrCodecConfigRow = struct {
    config_id: i64,
    track_id: i64,
    codec_tag: []const u8,
    container_width: i64,
    container_height: i64,
    bitstream_width: i64,
    bitstream_height: i64,
    is_mismatch: bool,
};

/// Strongly-typed row for `ir_deep.ir_attachments` (`configs/schemas.yaml`).
pub const IrAttachmentRow = struct {
    attachment_id: i64,
    file_name: []const u8,
    mime_type: []const u8,
    payload_offset: u64,
    payload_length: u64,
};

/// Strongly-typed row for `ir_deep.ir_external_refs` (`configs/schemas.yaml`).
pub const IrExternalRefRow = struct {
    ref_id: i64,
    track_id: i64,
    source_tag: []const u8,
    file_offset: u64,
    target_url: []const u8,
};

/// Byte interval `[start, end)` representing either a media container payload (`mdat`, `movi`, `Cluster`)
/// or a referenced sample/chunk extent.
pub const ByteInterval = struct {
    tag: []const u8 = "",
    start: u64,
    end: u64,

    fn lessThan(_: void, a: ByteInterval, b: ByteInterval) bool {
        if (a.start != b.start) return a.start < b.start;
        return a.end < b.end;
    }
};

/// Computes all unreferenced byte gaps inside `media_regions` that are not covered by any interval
/// in `referenced_extents`. Shared across `isobmff`, `ebml`, and `riff` for `R08` slack detection.
pub fn computeUnreferencedSlack(
    allocator: Allocator,
    media_regions: []const ByteInterval,
    referenced_extents: []const ByteInterval,
) ![]IrUnreferencedSlackRow {
    const sorted_refs = try allocator.dupe(ByteInterval, referenced_extents);
    defer allocator.free(sorted_refs);
    std.mem.sort(ByteInterval, sorted_refs, {}, ByteInterval.lessThan);

    var slack_list: std.ArrayListUnmanaged(IrUnreferencedSlackRow) = .empty;
    errdefer slack_list.deinit(allocator);

    var next_id: i64 = 1;

    for (media_regions) |region| {
        if (region.end <= region.start) continue;
        var cursor = region.start;

        for (sorted_refs) |ext| {
            if (ext.end <= cursor) continue;
            if (ext.start >= region.end) break;

            const clamped_start = @max(ext.start, region.start);
            const clamped_end = @min(ext.end, region.end);

            if (clamped_start > cursor) {
                try slack_list.append(allocator, .{
                    .slack_id = next_id,
                    .region_tag = region.tag,
                    .file_offset = cursor,
                    .byte_length = clamped_start - cursor,
                });
                next_id += 1;
            }
            if (clamped_end > cursor) {
                cursor = clamped_end;
            }
        }

        if (cursor < region.end) {
            try slack_list.append(allocator, .{
                .slack_id = next_id,
                .region_tag = region.tag,
                .file_offset = cursor,
                .byte_length = region.end - cursor,
            });
            next_id += 1;
        }
    }

    return slack_list.toOwnedSlice(allocator);
}
