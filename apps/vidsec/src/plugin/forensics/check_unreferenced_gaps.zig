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

/// Detects disjoint unreferenced byte gaps between adjacent root containers.
pub fn checkUnreferencedGaps(
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

        if (curr.end < next.start) {
            const gap_len = next.start - curr.end;
            const msg = try std.fmt.allocPrint(
                allocator,
                "Unreferenced gap between root regions {s} and {s}: {d} bytes at offset {d}",
                .{ curr.tag, next.tag, gap_len, curr.end },
            );
            try findings.append(allocator, .{
                .vulnerability = .unreferenced_gap,
                .severity = .warning,
                .offset = curr.end,
                .length = gap_len,
                .region_tag = "gap",
                .message = msg,
            });
        }
    }
}
