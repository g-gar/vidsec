const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("vidsec_ir");
const FindingList = @import("finding_list.zig").FindingList;

/// Detects regions whose declared size is less than the minimum header length (< 8 bytes).
pub fn checkHeaderUnderflow(
    allocator: Allocator,
    container: *const ir.ContainerIR,
    findings: *FindingList,
) !void {
    for (container.regions.items) |region| {
        if (region.size < 8 and region.role != .unknown) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Region {s} (id={d}) size underflow: {d} bytes < minimal 8-byte header",
                .{ region.tagSlice(), region.id, region.size },
            );
            try findings.append(allocator, .{
                .vulnerability = .header_underflow,
                .severity = .critical,
                .offset = region.header_offset,
                .length = region.size,
                .region_tag = region.tagSlice(),
                .message = msg,
            });
        }
    }
}
