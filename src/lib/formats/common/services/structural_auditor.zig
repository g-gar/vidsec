const std = @import("std");
const Allocator = std.mem.Allocator;
const Region = @import("../entities/element_span.zig").Region;
const DiagnosticList = @import("../entities/diagnostic_list.zig").DiagnosticList;
const checkGaps = @import("check_gaps.zig").checkGaps;
const checkOverlaps = @import("check_overlaps.zig").checkOverlaps;
const checkTrailingOverlay = @import("check_trailing_overlay.zig").checkTrailingOverlay;

/// Composite service orchestrating cross-region topological checks over parsed container regions.
pub const StructuralAuditor = struct {
    pub fn auditRegions(
        allocator: Allocator,
        regions: []const Region,
        file_size: u64,
        allow_gaps: bool,
        diagnostics: *DiagnosticList,
    ) !void {
        try checkOverlaps(allocator, regions, diagnostics);
        try checkGaps(allocator, regions, allow_gaps, diagnostics);
        try checkTrailingOverlay(allocator, regions, file_size, diagnostics);
    }

    pub const auditSpans = auditRegions;
};
