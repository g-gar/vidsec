const std = @import("std");

/// Strongly-typed row for `audit.audit_findings` (`configs/schemas.yaml`).
pub const AuditFindingRow = struct {
    finding_id: ?i64 = null,
    rule_id: []const u8,
    severity: i64,
    file_offset: i64 = 0,
    byte_length: i64 = 0,
    end_offset: i64 = 0,
    region_tag: ?[]const u8 = null,
    measured_value: ?f64 = null,
    message: ?[]const u8 = null,
    is_remediated: bool = false,
    remediation_action: []const u8 = "UNRESOLVED",
};
