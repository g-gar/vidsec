//! Pure, zero-dependency Universal Container Intermediate Representation (IR)
//! and format-agnostic forensic analysis primitives (`topology`, `inconsistencies`,
//! `intervals`, `lowering_common`).

const std = @import("std");

// Domain entities
pub const container_format = @import("entities/container_format.zig");
pub const region_role = @import("entities/region_role.zig");
pub const track_type = @import("entities/track_type.zig");
pub const byte_stream = @import("entities/byte_stream.zig");
pub const slice_stream = @import("entities/slice_stream.zig");
pub const region = @import("entities/region.zig");
pub const track = @import("entities/track.zig");
pub const sample_extent = @import("entities/sample_extent.zig");
pub const container_ir = @import("entities/container_ir.zig");

// Pipeline relational rows
pub const rows = @import("rows/mod.zig");

// Findings & diagnostics
pub const severity = @import("findings/severity.zig");
pub const vulnerability_type = @import("findings/vulnerability_type.zig");
pub const finding = @import("findings/finding.zig");
pub const finding_list = @import("findings/finding_list.zig");
pub const audit_finding_row = @import("findings/audit_finding_row.zig");

// Format-agnostic analysis & lowering helpers
pub const intervals = @import("analysis/intervals.zig");
pub const lowering_types = @import("analysis/lowering_types.zig");
pub const lowering_common = @import("analysis/lowering_common.zig");
pub const topology = @import("analysis/topology.zig");
pub const inconsistencies = @import("analysis/inconsistencies.zig");
pub const common = @import("common/mod.zig");

// Canonical re-exports: Entities
pub const ContainerFormat = container_format.ContainerFormat;
pub const RegionRole = region_role.RegionRole;
pub const TrackType = track_type.TrackType;
pub const ByteStream = byte_stream.ByteStream;
pub const SliceStream = slice_stream.SliceStream;
pub const Region = region.Region;
pub const Track = track.Track;
pub const SampleExtent = sample_extent.SampleExtent;
pub const ContainerIR = container_ir.ContainerIR;

// Canonical re-exports: Rows
pub const ContainerMetadataRow = rows.ContainerMetadataRow;
pub const IrRegionRow = rows.IrRegionRow;
pub const IrSampleExtentRow = rows.IrSampleExtentRow;
pub const IrUnreferencedSlackRow = rows.IrUnreferencedSlackRow;
pub const IrCodecConfigRow = rows.IrCodecConfigRow;
pub const IrAttachmentRow = rows.IrAttachmentRow;
pub const IrExternalRefRow = rows.IrExternalRefRow;
pub const ByteInterval = rows.ByteInterval;
pub const computeUnreferencedSlack = rows.computeUnreferencedSlack;
pub const emitContainerMetadata = rows.emitContainerMetadata;
pub const emitIrRegion = rows.emitIrRegion;
pub const emitIrSampleExtent = rows.emitIrSampleExtent;
pub const emitIrUnreferencedSlack = rows.emitIrUnreferencedSlack;
pub const emitIrCodecConfig = rows.emitIrCodecConfig;
pub const emitIrAttachment = rows.emitIrAttachment;
pub const emitIrExternalRef = rows.emitIrExternalRef;

// Canonical re-exports: Findings
pub const Severity = severity.Severity;
pub const VulnerabilityType = vulnerability_type.VulnerabilityType;
pub const RuleId = vulnerability_type.RuleId;
pub const Finding = finding.Finding;
pub const FindingList = finding_list.FindingList;
pub const AuditFindingRow = audit_finding_row.AuditFindingRow;
pub const AuditFinding = AuditFindingRow;
pub const emitAuditFinding = audit_finding_row.emitAuditFinding;

// Canonical re-exports: Format-agnostic Analysis & Lowering
pub const Interval = intervals.Interval;
pub const RegionInput = lowering_types.RegionInput;
pub const LowerContainerOutput = lowering_types.LowerContainerOutput;
pub const lowerRegions = lowering_common.lowerRegions;
pub const TopologyOutput = topology.TopologyOutput;
pub const collectSortedRootIntervals = topology.collectSortedRootIntervals;
pub const detectUnreferencedGaps = topology.detectUnreferencedGaps;
pub const detectRegionOverlaps = topology.detectRegionOverlaps;
pub const detectTrailingOverlay = topology.detectTrailingOverlay;
pub const analyzeTopology = topology.analyzeTopology;
pub const checkInconsistencies = inconsistencies.checkInconsistencies;

test {
    std.testing.refAllDecls(@This());
}
