const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("vidsec_ir");
const FindingList = @import("finding_list.zig").FindingList;

/// Detects inconsistency between container declared dimensions and bitstream dimensions.
pub fn checkCodecMismatches(
    allocator: Allocator,
    container: *const ir.ContainerIR,
    findings: *FindingList,
) !void {
    for (container.tracks.items) |track| {
        if (track.hasDimensionMismatch()) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Track {d} resolution mismatch: container {d}x{d} != bitstream {d}x{d}",
                .{ track.id, track.container_width, track.container_height, track.bitstream_width, track.bitstream_height },
            );
            try findings.append(allocator, .{
                .vulnerability = .dimension_mismatch,
                .severity = .warning,
                .offset = 0,
                .length = 0,
                .region_tag = "codec",
                .message = msg,
            });
        }
    }
}
