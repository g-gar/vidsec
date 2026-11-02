const std = @import("std");
const abi = @import("vidsec_abi");
const math = @import("vidsec_math");

/// Task `forensics/scan_entropy`:
/// Inspects unreferenced slack and gap regions in `ir_unreferenced_slack`
/// using Shannon entropy to detect encrypted payloads, compressed archives, or shellcode.
pub fn runScanEntropy(ctx: abi.TaskContext) abi.SdkError!abi.TaskStatus_ABI {
    const min_entropy = try ctx.getParamFloat("min_entropy", 7.2);
    const stream = ctx.streamReader();

    var buf: [65536]u8 = undefined;

    while (try ctx.nextRow("slack")) |row| {
        const slack = row.into(abi.ir.IrUnreferencedSlackRow) orelse continue;
        if (slack.byte_length == 0) continue;

        const sample_len: usize = @intCast(@min(slack.byte_length, buf.len));
        const read_slice = buf[0..sample_len];
        try stream.readAt(slack.file_offset, read_slice);

        // Check if all zero (harmless padding)
        if (math.isAllZero(read_slice)) continue;

        const h = math.shannonEntropy(read_slice);
        if (h >= min_entropy) {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "High entropy payload in {s} (H={d:.2} >= {d:.2}): potential encrypted/compressed data",
                .{ slack.region_tag, h, min_entropy },
            ) catch "High entropy payload in slack";

            try abi.ir.emitAuditFinding(ctx, .{
                .rule_id = "R07_HIGH_ENTROPY_PAYLOAD",
                .severity = 2,
                .file_offset = @intCast(slack.file_offset),
                .byte_length = @intCast(slack.byte_length),
                .end_offset = @intCast(slack.file_offset + slack.byte_length),
                .region_tag = slack.region_tag,
                .measured_value = h,
                .message = msg,
                .is_remediated = false,
                .remediation_action = "UNRESOLVED",
            });
        }
    }

    return .ok;
}
