const std = @import("std");
const abi = @import("vidsec_abi");
const math = @import("vidsec_math");
const ir = @import("vidsec_ir");
const forensics = @import("vidsec_forensics");

const Interval = math.Interval;

pub const AnalyzeTopologyInputs = struct {
    stream: abi.BoundedStreamReader,
    file_size: u64 = 0,
    highest_root_end: u64 = 0,
    prev_verdict: ?i64 = null,
    allow_trailing_slack: bool = false,
    max_trailing_slack_bytes: u64 = 0,
};

/// Task `forensics/analyze_topology`:
/// Analyzes root intervals in `ir_regions` against `container_metadata` to detect:
/// - R01: Trailing unreferenced slack/overlay (`highest_root_end < file_size`).
/// - R02: Gaps between root container regions.
/// - R05: Overlapping root regions (structural confusion attacks).
/// Populates `ir_unreferenced_slack` and emits findings into `audit_findings`.
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

    var root_intervals: std.ArrayListUnmanaged(Interval) = .empty;

    // 2. Read root regions (where parent_region_id IS NULL)
    while (try ctx.nextRow("regions")) |reg_row| {
        const reg = reg_row.into(ir.IrRegionRow) orelse continue;
        if (reg.parent_region_id != null) continue; // Only inspect root-level regions

        const owned_tag = try allocator.dupe(u8, reg.tag_name);
        try root_intervals.append(allocator, .{
            .start = reg.header_offset,
            .end = reg.effective_end_offset,
            .tag = owned_tag,
        });
    }

    var slack_counter: i64 = 1;

    // 3. Check for leading unreferenced gap before first box
    if (root_intervals.items.len > 0) {
        std.mem.sort(Interval, root_intervals.items, {}, Interval.lessThan);

        const first_start = root_intervals.items[0].start;
        if (first_start > 0) {
            const lead_gap = first_start;
            try ir.emitIrUnreferencedSlack(ctx, .{
                .slack_id = slack_counter,
                .region_tag = "leading_slack",
                .file_offset = 0,
                .byte_length = lead_gap,
            });
            slack_counter += 1;

            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Unreferenced leading gap of {d} bytes before container start",
                .{lead_gap},
            ) catch "Leading unreferenced gap";

            try forensics.emitAuditFinding(ctx, .{
                .rule_id = "R02_UNREFERENCED_GAP",
                .severity = 2,
                .file_offset = 0,
                .byte_length = @intCast(lead_gap),
                .end_offset = @intCast(lead_gap),
                .region_tag = "leading_slack",
                .measured_value = @floatFromInt(lead_gap),
                .message = msg,
                .is_remediated = false,
                .remediation_action = "UNRESOLVED",
            });
        }
    }

    // 4. Check for gaps between adjacent root intervals and overlapping regions
    var prev_end: u64 = if (root_intervals.items.len > 0) root_intervals.items[0].start else 0;
    for (root_intervals.items) |iv| {
        if (iv.start > prev_end) {
            const gap_len = iv.start - prev_end;
            try ir.emitIrUnreferencedSlack(ctx, .{
                .slack_id = slack_counter,
                .region_tag = "unreferenced_gap",
                .file_offset = prev_end,
                .byte_length = gap_len,
            });
            slack_counter += 1;

            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Unreferenced gap of {d} bytes between offset {d} and {d}",
                .{ gap_len, prev_end, iv.start },
            ) catch "Unreferenced gap between root regions";

            try forensics.emitAuditFinding(ctx, .{
                .rule_id = "R02_UNREFERENCED_GAP",
                .severity = 2,
                .file_offset = @intCast(prev_end),
                .byte_length = @intCast(gap_len),
                .end_offset = @intCast(iv.start),
                .region_tag = "unreferenced_gap",
                .measured_value = @floatFromInt(gap_len),
                .message = msg,
                .is_remediated = false,
                .remediation_action = "UNRESOLVED",
            });
        } else if (iv.start < prev_end and prev_end > 0) {
            const overlap_len = prev_end - iv.start;
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Overlapping root regions detected at offset {d} (overlap={d} bytes)",
                .{ iv.start, overlap_len },
            ) catch "Overlapping root regions";

            try forensics.emitAuditFinding(ctx, .{
                .rule_id = "R05_REGION_OVERLAP",
                .severity = 2,
                .file_offset = @intCast(iv.start),
                .byte_length = @intCast(overlap_len),
                .end_offset = @intCast(prev_end),
                .region_tag = "region_overlap",
                .measured_value = @floatFromInt(overlap_len),
                .message = msg,
                .is_remediated = false,
                .remediation_action = "UNRESOLVED",
            });
        }

        prev_end = @max(prev_end, iv.end);
        highest_root_end = @max(highest_root_end, iv.end);
    }

    // 5. Check for trailing overlay beyond `highest_root_end`
    if (highest_root_end > 0 and highest_root_end < file_size) {
        const trailing_len = file_size - highest_root_end;
        if (trailing_len > 0) {
            try ir.emitIrUnreferencedSlack(ctx, .{
                .slack_id = slack_counter,
                .region_tag = "trailing_overlay",
                .file_offset = highest_root_end,
                .byte_length = trailing_len,
            });
            slack_counter += 1;

            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Trailing unreferenced overlay of {d} bytes beyond offset {d} (EOF={d})",
                .{ trailing_len, highest_root_end, file_size },
            ) catch "Trailing overlay detected";

            try forensics.emitAuditFinding(ctx, .{
                .rule_id = "R01_TRAILING_OVERLAY",
                .severity = 2,
                .file_offset = @intCast(highest_root_end),
                .byte_length = @intCast(trailing_len),
                .end_offset = @intCast(file_size),
                .region_tag = "trailing_overlay",
                .measured_value = @floatFromInt(trailing_len),
                .message = msg,
                .is_remediated = false,
                .remediation_action = "UNRESOLVED",
            });
        }
    }

    return .ok;
}
