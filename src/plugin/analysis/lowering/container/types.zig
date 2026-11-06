const std = @import("std");
const ir = @import("vidsec_ir");
const forensics = @import("vidsec_forensics");

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
    regions: []const ir.IrRegionRow,
    metadata: ir.ContainerMetadataRow,
    overflow_findings: []const forensics.AuditFindingRow,
};
