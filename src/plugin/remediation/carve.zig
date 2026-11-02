const std = @import("std");
const abi = @import("vidsec_abi");

/// Task `remediation/carve_quarantine`:
/// Scans critical findings in `audit_findings` (e.g. polyglot overlays, unreferenced scripts)
/// and extracts/carves their payload to the Host quarantine directory via `ctx.carveToQuarantine`.
pub fn runCarveQuarantine(ctx: abi.TaskContext) abi.SdkError!abi.TaskStatus_ABI {
    while (try ctx.nextRow("threats")) |threat_row| {
        const finding_id = if (threat_row.getField("finding_id")) |f| f.asInt() orelse 0 else 0;
        const offset_i = if (threat_row.getField("file_offset")) |f| f.asInt() orelse 0 else 0;
        const length_i = if (threat_row.getField("byte_length")) |f| f.asInt() orelse 0 else 0;
        const rule_id = if (threat_row.getField("rule_id")) |f| f.asText() orelse "threat" else "threat";

        if (offset_i < 0 or length_i <= 0) continue;
        const offset: u64 = @intCast(offset_i);
        const length: u64 = @intCast(length_i);

        const stream_size = ctx.streamSize();
        if (offset >= stream_size) continue;
        const effective_len = @min(length, stream_size - offset);

        var reason_buf: [128:0]u8 = undefined;
        const reason = std.fmt.bufPrintZ(&reason_buf, "finding_{d}_{s}", .{ finding_id, rule_id }) catch "quarantine_threat";

        const sha_hex = try ctx.carveToQuarantine(offset, effective_len, reason);
        ctx.logInfo(&sha_hex);
    }

    return .ok;
}
