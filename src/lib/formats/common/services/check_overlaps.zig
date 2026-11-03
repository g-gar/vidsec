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

/// Service detecting illegal byte overlaps between root container regions.
pub fn checkOverlaps(
    allocator: Allocator,
    regions: []const Region,
    diagnostics: *DiagnosticList,
) !void {
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

        if (next.offset < curr.end) {
            const overlap_len = curr.end - next.offset;
            const msg = try std.fmt.allocPrint(
                allocator,
                "Overlapping root elements: {s} [..{d}] overlaps with {s} [{d}..] by {d} bytes",
                .{ curr.tag, curr.end, next.tag, next.offset, overlap_len },
            );
            try diagnostics.append(allocator, .{
                .rule_id = "structural.element_overlap",
                .severity = .critical,
                .start_offset = next.offset,
                .end_offset = curr.end,
                .byte_length = overlap_len,
                .element_id = &next.tag,
                .message = msg,
            });
        }
    }
}
