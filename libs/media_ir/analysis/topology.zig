const std = @import("std");
const math = @import("intervals.zig");
const ir = @import("../rows/mod.zig");
const RuleId = @import("../findings/vulnerability_type.zig").RuleId;
const forensics = struct {
    pub const AuditFinding = @import("../findings/audit_finding_row.zig").AuditFindingRow;
};

const Interval = math.Interval;

pub const TopologyOutput = struct {
    slacks: []const ir.IrUnreferencedSlackRow,
    findings: []const forensics.AuditFinding,
};

/// Extracts root-level regions (`parent_region_id == null`) from `ir_regions`
/// and returns them sorted by `(start, end)` offset.
pub fn collectSortedRootIntervals(
    allocator: std.mem.Allocator,
    regions: []const ir.IrRegionRow,
) ![]Interval {
    var root_intervals = std.ArrayList(Interval).empty;
    errdefer root_intervals.deinit(allocator);

    for (regions) |reg| {
        if (reg.parent_region_id != null) continue;
        try root_intervals.append(allocator, .{
            .start = reg.header_offset,
            .end = reg.effective_end_offset,
            .tag = reg.tag_name,
        });
    }

    std.mem.sort(Interval, root_intervals.items, {}, Interval.lessThan);
    return try root_intervals.toOwnedSlice(allocator);
}

/// Detects unreferenced leading gaps (before the first root region) and interior gaps
/// between adjacent root regions (`UNREFERENCED_GAP`).
///
/// Produces:
/// - `slacks`: `IrUnreferencedSlackRow` descriptors (`leading_slack`, `unreferenced_gap`)
/// - `findings`: `AuditFinding` records with `rule_id = RuleId.unreferenced_gap.asText()`
pub fn detectUnreferencedGapsFromIntervals(
    allocator: std.mem.Allocator,
    root_intervals: []const Interval,
) !TopologyOutput {
    var slacks = std.ArrayList(ir.IrUnreferencedSlackRow).empty;
    errdefer slacks.deinit(allocator);

    var findings = std.ArrayList(forensics.AuditFinding).empty;
    errdefer findings.deinit(allocator);

    if (root_intervals.len == 0) {
        return .{
            .slacks = try slacks.toOwnedSlice(allocator),
            .findings = try findings.toOwnedSlice(allocator),
        };
    }

    var slack_counter: i64 = 1;

    const first_start = root_intervals[0].start;
    if (first_start > 0) {
        try slacks.append(allocator, .{
            .slack_id = slack_counter,
            .region_tag = "leading_slack",
            .file_offset = 0,
            .byte_length = first_start,
        });
        slack_counter += 1;

        const msg = try std.fmt.allocPrint(
            allocator,
            "Unreferenced leading gap of {d} bytes before container start",
            .{first_start},
        );
        try findings.append(allocator, .{
            .rule_id = RuleId.unreferenced_gap.asText(),
            .severity = 2,
            .file_offset = 0,
            .byte_length = @intCast(first_start),
            .end_offset = @intCast(first_start),
            .region_tag = "leading_slack",
            .measured_value = @floatFromInt(first_start),
            .message = msg,
            .is_remediated = false,
            .remediation_action = "UNRESOLVED",
        });
    }

    var prev_end: u64 = root_intervals[0].start;
    for (root_intervals) |iv| {
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
                .rule_id = RuleId.unreferenced_gap.asText(),
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
        }
        prev_end = @max(prev_end, iv.end);
    }

    return .{
        .slacks = try slacks.toOwnedSlice(allocator),
        .findings = try findings.toOwnedSlice(allocator),
    };
}

/// Detects unreferenced leading and inter-region gaps directly from `ir_regions`.
pub fn detectUnreferencedGaps(
    allocator: std.mem.Allocator,
    regions: []const ir.IrRegionRow,
) !TopologyOutput {
    const intervals = try collectSortedRootIntervals(allocator, regions);
    defer allocator.free(intervals);
    return detectUnreferencedGapsFromIntervals(allocator, intervals);
}

/// Detects overlapping root container regions (`REGION_OVERLAP`),
/// indicative of structural confusion / parser-differential attacks.
pub fn detectRegionOverlapsFromIntervals(
    allocator: std.mem.Allocator,
    root_intervals: []const Interval,
) ![]const forensics.AuditFinding {
    var findings = std.ArrayList(forensics.AuditFinding).empty;
    errdefer findings.deinit(allocator);

    if (root_intervals.len == 0) {
        return try findings.toOwnedSlice(allocator);
    }

    var prev_end: u64 = root_intervals[0].start;
    for (root_intervals) |iv| {
        if (iv.start < prev_end and prev_end > 0) {
            const overlap_len = prev_end - iv.start;
            const msg = try std.fmt.allocPrint(
                allocator,
                "Overlapping root regions detected at offset {d} (overlap={d} bytes)",
                .{ iv.start, overlap_len },
            );
            try findings.append(allocator, .{
                .rule_id = RuleId.region_overlap.asText(),
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
    }

    return try findings.toOwnedSlice(allocator);
}

/// Detects overlapping root regions directly from `ir_regions`.
pub fn detectRegionOverlaps(
    allocator: std.mem.Allocator,
    regions: []const ir.IrRegionRow,
) ![]const forensics.AuditFinding {
    const intervals = try collectSortedRootIntervals(allocator, regions);
    defer allocator.free(intervals);
    return detectRegionOverlapsFromIntervals(allocator, intervals);
}

/// Detects trailing unreferenced overlay bytes beyond `highest_root_end` up to `file_size`
/// (`TRAILING_OVERLAY`).
pub fn detectTrailingOverlayFromIntervals(
    allocator: std.mem.Allocator,
    file_size: u64,
    initial_highest_root_end: u64,
    root_intervals: []const Interval,
) !TopologyOutput {
    var slacks = std.ArrayList(ir.IrUnreferencedSlackRow).empty;
    errdefer slacks.deinit(allocator);

    var findings = std.ArrayList(forensics.AuditFinding).empty;
    errdefer findings.deinit(allocator);

    var highest_root_end = initial_highest_root_end;
    for (root_intervals) |iv| {
        highest_root_end = @max(highest_root_end, iv.end);
    }

    if (highest_root_end > 0 and highest_root_end < file_size) {
        const trailing_len = file_size - highest_root_end;
        try slacks.append(allocator, .{
            .slack_id = 1,
            .region_tag = "trailing_overlay",
            .file_offset = highest_root_end,
            .byte_length = trailing_len,
        });

        const msg = try std.fmt.allocPrint(
            allocator,
            "Trailing unreferenced overlay of {d} bytes beyond offset {d} (EOF={d})",
            .{ trailing_len, highest_root_end, file_size },
        );
        try findings.append(allocator, .{
            .rule_id = RuleId.trailing_overlay.asText(),
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

    return .{
        .slacks = try slacks.toOwnedSlice(allocator),
        .findings = try findings.toOwnedSlice(allocator),
    };
}

/// Detects trailing overlay directly from `ir_regions`, `file_size`, and `initial_highest_root_end`.
pub fn detectTrailingOverlay(
    allocator: std.mem.Allocator,
    file_size: u64,
    initial_highest_root_end: u64,
    regions: []const ir.IrRegionRow,
) !TopologyOutput {
    const intervals = try collectSortedRootIntervals(allocator, regions);
    defer allocator.free(intervals);
    return detectTrailingOverlayFromIntervals(allocator, file_size, initial_highest_root_end, intervals);
}

/// Composite topology analysis:
/// Composes gap detection (`unreferenced_gap`), overlap detection (`region_overlap`), and trailing overlay detection (`trailing_overlay`)
/// over root intervals in `ir_regions`.
pub fn analyzeTopology(
    allocator: std.mem.Allocator,
    file_size: u64,
    initial_highest_root_end: u64,
    regions: []const ir.IrRegionRow,
) !TopologyOutput {
    const intervals = try collectSortedRootIntervals(allocator, regions);
    defer allocator.free(intervals);

    const gaps = try detectUnreferencedGapsFromIntervals(allocator, intervals);
    const overlaps = try detectRegionOverlapsFromIntervals(allocator, intervals);
    const overlay = try detectTrailingOverlayFromIntervals(allocator, file_size, initial_highest_root_end, intervals);

    var slacks = std.ArrayList(ir.IrUnreferencedSlackRow).empty;
    errdefer slacks.deinit(allocator);
    try slacks.appendSlice(allocator, gaps.slacks);
    for (overlay.slacks) |s| {
        var row = s;
        row.slack_id = @intCast(slacks.items.len + 1);
        try slacks.append(allocator, row);
    }

    var findings = std.ArrayList(forensics.AuditFinding).empty;
    errdefer findings.deinit(allocator);
    try findings.appendSlice(allocator, gaps.findings);
    try findings.appendSlice(allocator, overlaps);
    try findings.appendSlice(allocator, overlay.findings);

    return .{
        .slacks = try slacks.toOwnedSlice(allocator),
        .findings = try findings.toOwnedSlice(allocator),
    };
}
