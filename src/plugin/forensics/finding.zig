const std = @import("std");
const Severity = @import("severity.zig").Severity;
const VulnerabilityType = @import("vulnerability_type.zig").VulnerabilityType;

/// Strongly-typed finding reported by a forensics rule.
pub const Finding = struct {
    vulnerability: VulnerabilityType,
    severity: Severity,
    offset: u64,
    length: u64,
    region_tag: []const u8,
    message: []const u8,
};
