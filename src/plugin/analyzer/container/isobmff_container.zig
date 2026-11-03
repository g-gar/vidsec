const std = @import("std");
const abi = @import("vidsec_abi");
const ir = @import("vidsec_ir");
const common = @import("common.zig");

pub const LowerIsobmffContainerInputs = struct {
    stream: abi.BoundedStreamReader,
    file_size: u64 = 0,
    true_magic_kind: i64 = 0,
    true_magic_name: []const u8 = "mp4",
};

/// Lowers ISOBMFF boxes from `boxes` channel into universal `ir_regions`
/// and emits consolidated `container_metadata`.
pub fn runLowerIsobmffContainer(
    ctx: abi.TaskContext,
    inputs: LowerIsobmffContainerInputs,
) abi.SdkError!abi.TaskStatus_ABI {
    const file_size: i64 = if (inputs.file_size > 0) @intCast(inputs.file_size) else @intCast(inputs.stream.len());
    var highest_root_end: i64 = 0;
    var lowered_count: usize = 0;

    while (try common.tryNextRow(ctx, "boxes", "isobmff_boxes")) |box_row| {
        const box_id = if (box_row.getField("box_id")) |v| v.asInt() orelse 0 else 0;
        const maybe_parent = if (box_row.getField("parent_box_id")) |v| v.asInt() else null;
        const fourcc = if (box_row.getField("fourcc")) |v| v.asText() orelse "????" else "????";
        const role = if (box_row.getField("role")) |v| v.asText() orelse "unknown" else "unknown";
        const header_offset = if (box_row.getField("header_offset")) |v| v.asInt() orelse 0 else 0;
        const payload_offset = if (box_row.getField("payload_offset")) |v| v.asInt() orelse 0 else 0;
        const box_size = if (box_row.getField("box_size")) |v| v.asInt() orelse 0 else 0;

        const effective_end_offset = header_offset + box_size;
        const is_truncated_or_overflow = (effective_end_offset > file_size);

        if (maybe_parent == null) {
            highest_root_end = @max(highest_root_end, effective_end_offset);
        }

        if (is_truncated_or_overflow) {
            try common.emitOverflowFinding(ctx, fourcc, header_offset, effective_end_offset, file_size);
        }

        try ir.emitIrRegion(ctx, .{
            .region_id = box_id,
            .parent_region_id = maybe_parent,
            .tag_name = fourcc,
            .role = role,
            .header_offset = @intCast(@max(0, header_offset)),
            .payload_offset = @intCast(@max(0, payload_offset)),
            .effective_end_offset = @intCast(@max(0, effective_end_offset)),
            .is_truncated_or_overflow = is_truncated_or_overflow,
        });
        lowered_count += 1;
    }

    try ir.emitContainerMetadata(ctx, .{
        .file_size = @intCast(@max(0, file_size)),
        .detected_format = ir.ContainerFormat.isobmff.toInt(),
        .true_magic = inputs.true_magic_kind,
        .true_magic_name = inputs.true_magic_name,
        .highest_root_end = @intCast(@max(0, highest_root_end)),
    });

    ctx.logInfoFmt("Consolidated IR container (ISOBMFF): format={s}, regions={d}, file_size={d}, highest_root_end={d}", .{
        inputs.true_magic_name,
        lowered_count,
        file_size,
        highest_root_end,
    });

    return .ok;
}
