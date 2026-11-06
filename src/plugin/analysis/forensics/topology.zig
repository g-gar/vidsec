const std = @import("std");
const math = @import("vidsec_math");
const ir = @import("vidsec_ir");
const forensics = @import("vidsec_forensics");

const Interval = math.Interval;

pub const TopologyOutput = struct {
    slacks: []const ir.IrUnreferencedSlackRow,
    findings: []const forensics.AuditFinding,
};

/// Pure Black Box topology analysis:
/// Analyzes root intervals in `ir_regions` against `container_metadata` to detect:
/// - R01: Trailing unreferenced slack/overlay (`highest_root_end < file_size`).
/// - R02: Gaps between root container regions.
/// - R05: Overlapping root regions (structural confusion attacks).
pub fn analyzeTopology(
    allocator: std.mem.Allocator,
    file_size: u64,
    initial_highest_root_end: u64,
    regions: []const ir.IrRegionRow,
) !TopologyOutput {
    var slacks = std.ArrayList(ir.IrUnreferencedSlackRow).empty;
    errdefer slacks.deinit(allocator);

    var findings = std.ArrayList(forensics.AuditFinding).empty;
    errdefer findings.deinit(allocator);

    var highest_root_end = initial_highest_root_end;

    var root_intervals = std.ArrayList(Interval).empty;
    defer root_intervals.deinit(allocator);

    for (regions) |reg| {
        if (reg.parent_region_id != null) continue; // Only inspect root-level regions

        try root_intervals.append(allocator, .{
            .start = reg.header_offset,
            .end = reg.effective_end_offset,
            .tag = reg.tag_name,
        });
    }

    var slack_counter: i64 = 1;

    // 1. Check for leading unreferenced gap before first box
    if (root_intervals.items.len > 0) {
        std.mem.sort(Interval, root_intervals.items, {}, Interval.lessThan);

        const first_start = root_intervals.items[0].start;
        if (first_start > 0) {
            const lead_gap = first_start;
            try slacks.append(allocator, .{
                .slack_id = slack_counter,
                .region_tag = "leading_slack",
                .file_offset = 0,
                .byte_length = lead_gap,
            });
            slack_counter += 1;

            const msg = try std.fmt.allocPrint(
                allocator,
                "Unreferenced leading gap of {d} bytes before container start",
                .{lead_gap},
            );

            try findings.append(allocator, .{
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

    // 2. Check for gaps between adjacent root intervals and overlapping regions
    var prev_end: u64 = if (root_intervals.items.len > 0) root_intervals.items[0].start else 0;
    for (root_intervals.items) |iv| {
        if (iv.start > prev_end) {
            const gap_len = iv.start - prev_end;
            try slacks.append(allocator, .{
                .slack_id = slack_counter,
                .region_tag = "unreferenced_gap",
                .file_offset = prev_end,
                .byte_length = gap_len,
            });
            slack_counter += 1;

            const msg = try std.fmt.allocPrint(
                allocator,
                "Unreferenced gap of {d} bytes between offset {d} and {d}",
                .{ gap_len, prev_end, iv.start },
            );

            try findings.append(allocator, .{
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
            const msg = try std.fmt.allocPrint(
                allocator,
                "Overlapping root regions detected at offset {d} (overlap={d} bytes)",
                .{ iv.start, overlap_len },
            );

            try findings.append(allocator, .{
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

    // 3. Check for trailing overlay beyond `highest_root_end`
    if (highest_root_end > 0 and highest_root_end < file_size) {
        const trailing_len = file_size - highest_root_end;
        if (trailing_len > 0) {
            try slacks.append(allocator, .{
                .slack_id = slack_counter,
                .region_tag = "trailing_overlay",
                .file_offset = highest_root_end,
                .byte_length = trailing_len,
            });
            slack_counter += 1;

            const msg = try std.fmt.allocPrint(
                allocator,
                "Trailing unreferenced overlay of {d} bytes beyond offset {d} (EOF={d})",
                .{ trailing_len, highest_root_end, file_size },
            );

            try findings.append(allocator, .{
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

    return .{
        .slacks = try slacks.toOwnedSlice(allocator),
        .findings = try findings.toOwnedSlice(allocator),
    };
}
