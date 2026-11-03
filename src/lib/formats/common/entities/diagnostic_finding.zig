const std = @import("std");
const Severity = @import("severity.zig").Severity;

/// Enriched format diagnostic finding containing forensic details and coordinates.
pub const DiagnosticFinding = struct {
    rule_id: []const u8,
    severity: Severity,
    start_offset: u64,
    end_offset: u64,
    byte_length: u64,
    element_id: []const u8,
    element_path: []const u8 = "",
    message: []const u8,
};
