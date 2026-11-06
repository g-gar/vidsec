const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("vidsec_ir");
const FindingList = @import("finding_list.zig").FindingList;

/// Detects unreferenced bytes before the first root container header (offset > 0).
pub fn checkLeadingGap(
    allocator: Allocator,
    container: *const ir.ContainerIR,
    findings: *FindingList,
) !void {
    var min_start: ?u64 = null;

    for (container.regions.items) |r| {
        if (r.parent_id == null) {
            min_start = if (min_start) |cur| @min(cur, r.header_offset) else r.header_offset;
        }
    }

    if (min_start) |start| {
        if (start > 0) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Leading unreferenced gap detected: {d} bytes before first root header",
                .{start},
            );
            try findings.append(allocator, .{
                .vulnerability = .leading_gap,
                .severity = .warning,
                .offset = 0,
                .length = start,
                .region_tag = "gap",
                .message = msg,
            });
        }
    }
}
