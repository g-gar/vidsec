const std = @import("std");

pub const severity = @import("severity.zig");
pub const vulnerability_type = @import("vulnerability_type.zig");
pub const finding = @import("finding.zig");
pub const finding_list = @import("finding_list.zig");

pub const check_header_underflow = @import("check_header_underflow.zig");
pub const check_region_overflow = @import("check_region_overflow.zig");
pub const check_trailing_overlay = @import("check_trailing_overlay.zig");
pub const check_leading_gap = @import("check_leading_gap.zig");
pub const check_unreferenced_gaps = @import("check_unreferenced_gaps.zig");
pub const check_region_overlaps = @import("check_region_overlaps.zig");
pub const check_sample_overflows = @import("check_sample_overflows.zig");
pub const check_codec_mismatches = @import("check_codec_mismatches.zig");
pub const check_entropy_payloads = @import("check_entropy_payloads.zig");
pub const forensics_suite = @import("forensics_suite.zig");

// Types
pub const Severity = severity.Severity;
pub const VulnerabilityType = vulnerability_type.VulnerabilityType;
pub const Finding = finding.Finding;
pub const FindingList = finding_list.FindingList;

// Independent Single-Responsibility Checkers
pub const checkHeaderUnderflow = check_header_underflow.checkHeaderUnderflow;
pub const checkRegionOverflow = check_region_overflow.checkRegionOverflow;
pub const checkTrailingOverlay = check_trailing_overlay.checkTrailingOverlay;
pub const checkLeadingGap = check_leading_gap.checkLeadingGap;
pub const checkUnreferencedGaps = check_unreferenced_gaps.checkUnreferencedGaps;
pub const checkRegionOverlaps = check_region_overlaps.checkRegionOverlaps;
pub const checkSampleOverflows = check_sample_overflows.checkSampleOverflows;
pub const checkCodecMismatches = check_codec_mismatches.checkCodecMismatches;
pub const checkEntropyPayloads = check_entropy_payloads.checkEntropyPayloads;

// Composite Forensics Suite
pub const ForensicsOptions = forensics_suite.ForensicsOptions;
pub const runAllForensics = forensics_suite.runAllForensics;

test {
    std.testing.refAllDecls(@This());
}
