const std = @import("std");
const abi = @import("vidsec_abi");

/// Task `remediation/sanitize`:
/// Performs Content Disarm & Reconstruction (CDR) on the media container:
/// 1. Truncates trailing unreferenced slack/overlays (`R01_TRAILING_OVERLAY`).
/// 2. Zero-fills unreferenced gaps and slack payloads (`R02_UNREFERENCED_GAP`, `R07_HIGH_ENTROPY_PAYLOAD`, `R06_SUSPICIOUS_ATTACHMENT`).
/// 3. Updates `audit_findings` setting `is_remediated = true` and `remediation_action = ...`.
/// 4. Produces the sanitized artifact specified by `output.artifact` (e.g. `clean_video`).
pub fn runSanitize(ctx: abi.TaskContext) abi.SdkError!abi.TaskStatus_ABI {
    var legitimate_end: u64 = 0;
    var file_size: u64 = ctx.streamSize();

    // 1. Read metadata from `meta` cursor if available
    if (try ctx.nextRow("meta")) |meta_row| {
        if (meta_row.getField("highest_root_end")) |v| {
            if (v.asInt()) |k| legitimate_end = @intCast(@max(0, k));
        }
        if (meta_row.getField("file_size")) |v| {
            if (v.asInt()) |s| file_size = @intCast(@max(0, s));
        }
    }

    var truncated = false;

    // 2. Iterate through findings to apply remediation
    while (try ctx.nextRow("findings")) |row| {
        const finding_id = if (row.getField("finding_id")) |f| f.asInt() orelse 0 else 0;
        const rule_id = if (row.getField("rule_id")) |f| f.asText() orelse "" else "";
        const offset_i = if (row.getField("file_offset")) |f| f.asInt() orelse 0 else 0;
        const length_i = if (row.getField("byte_length")) |f| f.asInt() orelse 0 else 0;

        if (std.mem.eql(u8, rule_id, "R01_TRAILING_OVERLAY")) {
            if (legitimate_end > 0 and legitimate_end < file_size and !truncated) {
                try ctx.artifactTruncate(legitimate_end);
                truncated = true;
            }
            try emitRemediationUpdate(ctx, finding_id, "TRUNCATED_OVERLAY");
        } else if (std.mem.eql(u8, rule_id, "R02_UNREFERENCED_GAP") or
            std.mem.eql(u8, rule_id, "R07_HIGH_ENTROPY_PAYLOAD"))
        {
            if (offset_i >= 0 and length_i > 0) {
                const off: u64 = @intCast(offset_i);
                const len: u64 = @intCast(length_i);
                if (off + len <= file_size) {
                    try ctx.artifactZeroRange(off, len);
                }
            }
            try emitRemediationUpdate(ctx, finding_id, "ZERO_FILLED_GAP");
        } else if (std.mem.eql(u8, rule_id, "R06_SUSPICIOUS_ATTACHMENT")) {
            if (offset_i >= 0 and length_i > 0) {
                const off: u64 = @intCast(offset_i);
                const len: u64 = @intCast(length_i);
                if (off + len <= file_size) {
                    try ctx.artifactZeroRange(off, len);
                }
            }
            try emitRemediationUpdate(ctx, finding_id, "STRIPPED_ATTACHMENT");
        }
    }

    return .ok;
}

fn emitRemediationUpdate(ctx: abi.TaskContext, finding_id: i64, action: []const u8) !void {
    try ctx.emitRow(null, &.{
        abi.NamedField_ABI.init("finding_id", abi.Value_ABI.fromInt(finding_id)),
        abi.NamedField_ABI.init("is_remediated", abi.Value_ABI.fromBool(true)),
        abi.NamedField_ABI.init("remediation_action", abi.Value_ABI.fromText(action)),
    });
}
