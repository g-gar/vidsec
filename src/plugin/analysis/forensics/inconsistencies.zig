const std = @import("std");
const ir = @import("vidsec_ir");
const forensics = @import("vidsec_forensics");

/// Pure Black Box inconsistencies task:
/// Audits codec configuration discrepancies and sample boundary integrity:
/// - R10: Inconsistencies between container dimensions and bitstream SPS dimensions.
/// - R08: Sample extents pointing outside media container boundaries or EOF.
pub fn checkInconsistencies(
    allocator: std.mem.Allocator,
    file_size: u64,
    configs: []const ir.IrCodecConfigRow,
    extents: []const ir.IrSampleExtentRow,
) ![]forensics.AuditFinding {
    var findings = std.ArrayList(forensics.AuditFinding).empty;
    errdefer findings.deinit(allocator);

    // 1. Audit codec configs
    for (configs) |config| {
        if (config.is_mismatch) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Track {d} resolution mismatch: container {d}x{d} != bitstream {d}x{d}",
                .{ config.track_id, config.container_width, config.container_height, config.bitstream_width, config.bitstream_height },
            );

            try findings.append(allocator, .{
                .rule_id = "R10_DIMENSION_MISMATCH",
                .severity = 1,
                .file_offset = 0,
                .byte_length = 0,
                .end_offset = 0,
                .region_tag = "codec_config",
                .measured_value = @floatFromInt(config.track_id),
                .message = msg,
                .is_remediated = false,
                .remediation_action = "UNRESOLVED",
            });
        }
    }

    // 2. Audit sample extents
    for (extents) |extent| {
        if (extent.end_offset > file_size) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Sample extent {d} overflows EOF: offset={d}, end={d} > file_size={d}",
                .{ extent.extent_id, extent.target_offset, extent.end_offset, file_size },
            );

            try findings.append(allocator, .{
                .rule_id = "R08_SAMPLE_EXTENT_OVERFLOW",
                .severity = 2,
                .file_offset = @intCast(extent.target_offset),
                .byte_length = @intCast(extent.byte_size),
                .end_offset = @intCast(extent.end_offset),
                .region_tag = "sample_extent",
                .measured_value = @floatFromInt(extent.end_offset),
                .message = msg,
                .is_remediated = false,
                .remediation_action = "UNRESOLVED",
            });
        }
    }

    return try findings.toOwnedSlice(allocator);
}
