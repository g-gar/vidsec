const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("vidsec_ir");
const FindingList = @import("finding_list.zig").FindingList;

/// Detects sample extents pointing outside physical container bounds.
pub fn checkSampleOverflows(
    allocator: Allocator,
    container: *const ir.ContainerIR,
    findings: *FindingList,
) !void {
    for (container.samples.items) |sample| {
        if (sample.isOverflow(container.file_size)) {
            const end = sample.endOffset();
            const msg = try std.fmt.allocPrint(
                allocator,
                "Sample extent (id={d}, track={d}) overflows EOF: offset={d}, end={d} > file_size={d}",
                .{ sample.extent_id, sample.track_id, sample.target_offset, end, container.file_size },
            );
            try findings.append(allocator, .{
                .vulnerability = .sample_overflow,
                .severity = .critical,
                .offset = sample.target_offset,
                .length = sample.byte_size,
                .region_tag = "sample",
                .message = msg,
            });
        }
    }
}
