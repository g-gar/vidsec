const std = @import("std");
const Allocator = std.mem.Allocator;
const Region = @import("../entities/element_span.zig").Region;
const DiagnosticList = @import("../entities/diagnostic_list.zig").DiagnosticList;
const DiagnosticFinding = @import("../entities/diagnostic_finding.zig").DiagnosticFinding;

const RegionInterval = struct {
    offset: u64,
    end: u64,
    tag: [4]u8,

    fn lessThan(_: void, a: RegionInterval, b: RegionInterval) bool {
        if (a.offset != b.offset) return a.offset < b.offset;
        return a.end < b.end;
    }
};

/// Service detecting unreferenced gaps between adjacent root regions.
pub fn checkGaps(
    allocator: Allocator,
    regions: []const Region,
    allow_gaps: bool,
    diagnostics: *DiagnosticList,
) !void {
    if (allow_gaps) return;

    var roots: std.ArrayListUnmanaged(RegionInterval) = .empty;
    defer roots.deinit(allocator);

    for (regions) |reg| {
        if (reg.parent_id == null) {
            try roots.append(allocator, .{
                .offset = reg.header_offset,
                .end = reg.effectiveEnd(),
                .tag = reg.tag,
            });
        }
    }

    if (roots.items.len < 2) return;
    std.mem.sort(RegionInterval, roots.items, {}, RegionInterval.lessThan);

    var i: usize = 0;
    while (i + 1 < roots.items.len) : (i += 1) {
        const curr = roots.items[i];
        const next = roots.items[i + 1];

        if (curr.end < next.offset) {
            const gap_len = next.offset - curr.end;
            const msg = try std.fmt.allocPrint(
                allocator,
                "Unreferenced gap between root elements {s} and {s}: {d} bytes at offset {d}",
                .{ curr.tag, next.tag, gap_len, curr.end },
            );
            try diagnostics.append(allocator, .{
                .rule_id = "structural.unreferenced_gap",
                .severity = .warning,
                .start_offset = curr.end,
                .end_offset = next.offset,
                .byte_length = gap_len,
                .element_id = "GAP",
                .message = msg,
            });
        }
    }
}
