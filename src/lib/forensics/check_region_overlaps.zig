const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("vidsec_ir");
const FindingList = @import("finding_list.zig").FindingList;

const IntervalItem = struct {
    tag: [4]u8,
    start: u64,
    end: u64,

    fn lessThan(_: void, a: IntervalItem, b: IntervalItem) bool {
        if (a.start != b.start) return a.start < b.start;
        return a.end < b.end;
    }
};

/// Detects overlapping intervals among root containers (structural confusion).
pub fn checkRegionOverlaps(
    allocator: Allocator,
    container: *const ir.ContainerIR,
    findings: *FindingList,
) !void {
    var root_list: std.ArrayListUnmanaged(IntervalItem) = .empty;
    defer root_list.deinit(allocator);

    for (container.regions.items) |r| {
        if (r.parent_id == null) {
            try root_list.append(allocator, .{
                .tag = r.tag,
                .start = r.header_offset,
                .end = r.effectiveEnd(),
            });
        }
    }

    if (root_list.items.len < 2) return;
    std.mem.sort(IntervalItem, root_list.items, {}, IntervalItem.lessThan);

    var i: usize = 0;
    while (i + 1 < root_list.items.len) : (i += 1) {
        const curr = root_list.items[i];
        const next = root_list.items[i + 1];

        if (curr.end > next.start) {
            const overlap_len = curr.end - next.start;
            const msg = try std.fmt.allocPrint(
                allocator,
                "Overlapping root regions detected between {s} [..{d}] and {s} [{d}..]: {d} bytes overlap",
                .{ curr.tag, curr.end, next.tag, next.start, overlap_len },
            );
            try findings.append(allocator, .{
                .vulnerability = .region_overlap,
                .severity = .critical,
                .offset = next.start,
                .length = overlap_len,
                .region_tag = "overlap",
                .message = msg,
            });
        }
    }
}
