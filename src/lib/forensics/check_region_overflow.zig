const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("vidsec_ir");
const FindingList = @import("finding_list.zig").FindingList;

/// Detects regions whose upper byte bounds exceed physical file size.
pub fn checkRegionOverflow(
    allocator: Allocator,
    container: *const ir.ContainerIR,
    findings: *FindingList,
) !void {
    for (container.regions.items) |region| {
        if (region.isOverflow(container.file_size)) {
            const effective_end = region.effectiveEnd();
            const msg = try std.fmt.allocPrint(
                allocator,
                "Region {s} (id={d}) overflows file bounds: offset={d} end={d} > file_size={d}",
                .{ region.tagSlice(), region.id, region.header_offset, effective_end, container.file_size },
            );
            try findings.append(allocator, .{
                .vulnerability = .region_overflow,
                .severity = .critical,
                .offset = region.header_offset,
                .length = region.size,
                .region_tag = region.tagSlice(),
                .message = msg,
            });
        }
    }
}
