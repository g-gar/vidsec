const std = @import("std");
const Allocator = std.mem.Allocator;
const Region = @import("../entities/element_span.zig").Region;
const DiagnosticList = @import("../entities/diagnostic_list.zig").DiagnosticList;
const DiagnosticFinding = @import("../entities/diagnostic_finding.zig").DiagnosticFinding;

/// Service detecting trailing overlay / appended slack bytes past the final root region.
pub fn checkTrailingOverlay(
    allocator: Allocator,
    regions: []const Region,
    file_size: u64,
    diagnostics: *DiagnosticList,
) !void {
    var max_end: u64 = 0;

    for (regions) |reg| {
        if (reg.parent_id == null) {
            const end = reg.effectiveEnd();
            if (end > max_end) {
                max_end = end;
            }
        }
    }

    if (max_end > 0 and max_end < file_size) {
        const trailing_bytes = file_size - max_end;
        const msg = try std.fmt.allocPrint(
            allocator,
            "Detected {d} unreferenced trailing overlay bytes past container end ({d}..{d})",
            .{ trailing_bytes, max_end, file_size },
        );
        try diagnostics.append(allocator, .{
            .rule_id = "structural.trailing_overlay",
            .severity = .warning,
            .start_offset = max_end,
            .end_offset = file_size,
            .byte_length = trailing_bytes,
            .element_id = "OVERLAY",
            .message = msg,
        });
    }
}
