const std = @import("std");
const abi = @import("vidsec_abi");
const ir = @import("vidsec_ir");
const common = @import("common.zig");

pub const LowerRiffContainerInputs = struct {
    stream: abi.BoundedStreamReader,
    file_size: u64 = 0,
    true_magic_kind: i64 = 0,
    true_magic_name: []const u8 = "avi",
};

/// Lowers RIFF chunks from `chunks` channel into universal `ir_regions`
/// and emits consolidated `container_metadata`.
pub fn runLowerRiffContainer(
    ctx: abi.TaskContext,
    inputs: LowerRiffContainerInputs,
) abi.SdkError!abi.TaskStatus_ABI {
    const file_size: i64 = if (inputs.file_size > 0) @intCast(inputs.file_size) else @intCast(inputs.stream.len());
    var highest_root_end: i64 = 0;
    var lowered_count: usize = 0;

    while (try common.tryNextRow(ctx, "chunks", "riff_chunks")) |chunk_row| {
        const chunk_id = if (chunk_row.getField("chunk_id")) |v| v.asInt() orelse 0 else 0;
        const maybe_parent = if (chunk_row.getField("parent_chunk_id")) |v| v.asInt() else null;
        const fourcc = if (chunk_row.getField("fourcc")) |v| v.asText() orelse "????" else "????";
        const role = if (chunk_row.getField("role")) |v| v.asText() orelse "unknown" else "unknown";
        const header_offset = if (chunk_row.getField("header_offset")) |v| v.asInt() orelse 0 else 0;
        const payload_offset = if (chunk_row.getField("payload_offset")) |v| v.asInt() orelse 0 else 0;
        const total_size = if (chunk_row.getField("total_size")) |v| v.asInt() orelse 0 else 0;

        const effective_end_offset = header_offset + total_size;
        const is_truncated_or_overflow = (effective_end_offset > file_size);

        if (maybe_parent == null) {
            highest_root_end = @max(highest_root_end, effective_end_offset);
        }

        if (is_truncated_or_overflow) {
            try common.emitOverflowFinding(ctx, fourcc, header_offset, effective_end_offset, file_size);
        }

        const fields = [_]abi.NamedField_ABI{
            abi.NamedField_ABI.init("region_id", abi.Value_ABI.fromInt(chunk_id)),
            abi.NamedField_ABI.init("parent_region_id", if (maybe_parent) |p| abi.Value_ABI.fromInt(p) else abi.Value_ABI.nullVal()),
            abi.NamedField_ABI.init("tag_name", abi.Value_ABI.fromText(fourcc)),
            abi.NamedField_ABI.init("role", abi.Value_ABI.fromText(role)),
            abi.NamedField_ABI.init("header_offset", abi.Value_ABI.fromInt(header_offset)),
            abi.NamedField_ABI.init("payload_offset", abi.Value_ABI.fromInt(payload_offset)),
            abi.NamedField_ABI.init("effective_end_offset", abi.Value_ABI.fromInt(effective_end_offset)),
            abi.NamedField_ABI.init("is_truncated_or_overflow", abi.Value_ABI.fromBool(is_truncated_or_overflow)),
        };

        try ctx.emitRow("ir_regions", &fields);
        lowered_count += 1;
    }

    const meta_fields = [_]abi.NamedField_ABI{
        abi.NamedField_ABI.init("file_size", abi.Value_ABI.fromInt(file_size)),
        abi.NamedField_ABI.init("detected_format", abi.Value_ABI.fromInt(ir.ContainerFormat.riff.toInt())),
        abi.NamedField_ABI.init("true_magic", abi.Value_ABI.fromInt(inputs.true_magic_kind)),
        abi.NamedField_ABI.init("true_magic_name", abi.Value_ABI.fromText(inputs.true_magic_name)),
        abi.NamedField_ABI.init("highest_root_end", abi.Value_ABI.fromInt(highest_root_end)),
    };

    try ctx.emitRow("container_metadata", &meta_fields);

    ctx.logInfoFmt("Consolidated IR container (RIFF): format={s}, regions={d}, file_size={d}, highest_root_end={d}", .{
        inputs.true_magic_name,
        lowered_count,
        file_size,
        highest_root_end,
    });

    return .ok;
}
