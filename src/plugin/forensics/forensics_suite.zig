const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("vidsec_ir");

const FindingList = @import("finding_list.zig").FindingList;
const check_header_underflow = @import("check_header_underflow.zig");
const check_region_overflow = @import("check_region_overflow.zig");
const check_trailing_overlay = @import("check_trailing_overlay.zig");
const check_leading_gap = @import("check_leading_gap.zig");
const check_unreferenced_gaps = @import("check_unreferenced_gaps.zig");
const check_region_overlaps = @import("check_region_overlaps.zig");
const check_sample_overflows = @import("check_sample_overflows.zig");
const check_codec_mismatches = @import("check_codec_mismatches.zig");
const check_entropy_payloads = @import("check_entropy_payloads.zig");

pub const ForensicsOptions = struct {
    check_underflows: bool = true,
    check_overflows: bool = true,
    check_overlays: bool = true,
    check_leading_gaps: bool = true,
    check_unreferenced_gaps: bool = true,
    check_overlaps: bool = true,
    check_samples: bool = true,
    check_codecs: bool = true,
    check_entropy: bool = true,
    entropy_options: check_entropy_payloads.EntropyForensicsOptions = .{},
};

/// Composes and executes all forensics checks over ContainerIR.
pub fn runAllForensics(
    allocator: Allocator,
    container: *const ir.ContainerIR,
    maybe_stream: ?ir.ByteStream,
    options: ForensicsOptions,
    findings: *FindingList,
) !void {
    if (options.check_underflows) {
        try check_header_underflow.checkHeaderUnderflow(allocator, container, findings);
    }
    if (options.check_overflows) {
        try check_region_overflow.checkRegionOverflow(allocator, container, findings);
    }
    if (options.check_overlays) {
        try check_trailing_overlay.checkTrailingOverlay(allocator, container, findings);
    }
    if (options.check_leading_gaps) {
        try check_leading_gap.checkLeadingGap(allocator, container, findings);
    }
    if (options.check_unreferenced_gaps) {
        try check_unreferenced_gaps.checkUnreferencedGaps(allocator, container, findings);
    }
    if (options.check_overlaps) {
        try check_region_overlaps.checkRegionOverlaps(allocator, container, findings);
    }
    if (options.check_samples) {
        try check_sample_overflows.checkSampleOverflows(allocator, container, findings);
    }
    if (options.check_codecs) {
        try check_codec_mismatches.checkCodecMismatches(allocator, container, findings);
    }
    if (options.check_entropy) {
        if (maybe_stream) |stream| {
            try check_entropy_payloads.checkEntropyPayloads(allocator, container, stream, options.entropy_options, findings);
        }
    }
}
