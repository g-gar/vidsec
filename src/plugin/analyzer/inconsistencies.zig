const std = @import("std");
const abi = @import("vidsec_abi");
const ir = @import("vidsec_ir");
const forensics = @import("vidsec_forensics");

/// Task `forensics/check_inconsistencies`:
/// Audits codec configuration discrepancies and sample boundary integrity:
/// - R10: Inconsistencies between container dimensions and bitstream SPS dimensions.
/// - R08: Sample extents pointing outside media container boundaries or EOF.
pub fn runCheckInconsistencies(ctx: abi.TaskContext) abi.SdkError!abi.TaskStatus_ABI {
    const file_size: u64 = ctx.streamSize();

    // 1. Audit codec configs
    while (try ctx.nextRow("configs")) |row| {
        const config = row.into(ir.IrCodecConfigRow) orelse continue;
        if (config.is_mismatch) {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Track {d} resolution mismatch: container {d}x{d} != bitstream {d}x{d}",
                .{ config.track_id, config.container_width, config.container_height, config.bitstream_width, config.bitstream_height },
            ) catch "Resolution mismatch";

            try forensics.emitAuditFinding(ctx, .{
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
    while (try ctx.nextRow("extents")) |row| {
        const extent = row.into(ir.IrSampleExtentRow) orelse continue;

        if (extent.end_offset > file_size) {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Sample extent {d} overflows EOF: offset={d}, end={d} > file_size={d}",
                .{ extent.extent_id, extent.target_offset, extent.end_offset, file_size },
            ) catch "Sample extent overflow";

            try forensics.emitAuditFinding(ctx, .{
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

    return .ok;
}
