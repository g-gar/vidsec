const std = @import("std");
const rows = @import("../rows/mod.zig");
const AuditFindingRow = @import("../findings/audit_finding_row.zig").AuditFindingRow;

pub const RegionInput = struct {
    id: i64,
    parent_id: ?i64 = null,
    tag: []const u8,
    role: []const u8 = "unknown",
    header_offset: i64,
    payload_offset: i64,
    size: i64,
};

pub const LowerContainerOutput = struct {
    regions: []const rows.IrRegionRow,
    metadata: rows.ContainerMetadataRow,
    overflow_findings: []const AuditFindingRow,
};
