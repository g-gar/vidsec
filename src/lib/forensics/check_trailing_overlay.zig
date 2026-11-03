const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("vidsec_ir");
const FindingList = @import("finding_list.zig").FindingList;

/// Detects unreferenced trailing overlay past the highest legitimate root container.
pub fn checkTrailingOverlay(
    allocator: Allocator,
    container: *const ir.ContainerIR,
    findings: *FindingList,
) !void {
    if (container.file_size == 0) return;

    const highest_root_end = container.highestRootEnd();
    if (highest_root_end > 0 and highest_root_end < container.file_size) {
        const overlay_len = container.file_size - highest_root_end;
        const msg = try std.fmt.allocPrint(
            allocator,
            "Trailing unreferenced overlay detected: {d} bytes past offset {d} (file_size={d})",
            .{ overlay_len, highest_root_end, container.file_size },
        );
        try findings.append(allocator, .{
            .vulnerability = .trailing_overlay,
            .severity = .critical,
            .offset = highest_root_end,
            .length = overlay_len,
            .region_tag = "overlay",
            .message = msg,
        });
    }
}
