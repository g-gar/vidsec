const std = @import("std");
const abi = @import("vidsec_abi");
const forensics = @import("vidsec_forensics");

pub fn tryNextRow(
    ctx: abi.TaskContext,
    primary: [:0]const u8,
    alt: [:0]const u8,
) abi.SdkError!?abi.RowView_ABI {
    if (ctx.nextRow(primary)) |maybe_row| {
        return maybe_row;
    } else |err| {
        if (err == error.NotFound) {
            if (ctx.nextRow(alt)) |maybe_alt_row| {
                return maybe_alt_row;
            } else |alt_err| {
                if (alt_err == error.NotFound) return null;
                return alt_err;
            }
        }
        return err;
    }
}

pub fn emitOverflowFinding(
    ctx: abi.TaskContext,
    tag: []const u8,
    header_offset: i64,
    effective_end_offset: i64,
    file_size: i64,
) abi.SdkError!void {
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "Region {s} overflows file bounds: offset={d} end={d} > file_size={d}",
        .{ tag, header_offset, effective_end_offset, file_size },
    ) catch "Region overflow";

    try forensics.emitAuditFinding(ctx, .{
        .rule_id = "IR_REGION_OVERFLOW",
        .severity = 2,
        .file_offset = header_offset,
        .byte_length = effective_end_offset - header_offset,
        .end_offset = effective_end_offset,
        .region_tag = tag,
        .measured_value = @floatFromInt(effective_end_offset),
        .message = msg,
        .is_remediated = false,
        .remediation_action = "UNRESOLVED",
    });
}
