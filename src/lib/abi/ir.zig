const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const sdk = @import("sdk.zig");

pub const SdkError = sdk.SdkError;
pub const TaskContext = sdk.TaskContext;
pub const Value_ABI = types.Value_ABI;
pub const NamedField_ABI = types.NamedField_ABI;

// =============================================================================
// Domain Contracts Submodules
// =============================================================================
pub const contracts = struct {
    pub const triage = @import("contracts/triage.zig");
    pub const ir = @import("contracts/ir.zig");
    pub const audit = @import("contracts/audit.zig");
};

// =============================================================================
// 1. Pre-Triage Domain (`triage.file_triage`)
// =============================================================================
pub const DetectedFamily = contracts.triage.DetectedFamily;
pub const MagicKind = contracts.triage.MagicKind;
pub const FileTriageRow = contracts.triage.FileTriageRow;

/// Emits a `FileTriageRow` to the active output sink (`into: file_triage`).
pub fn emitFileTriage(ctx: TaskContext, row: FileTriageRow) SdkError!void {
    try ctx.emitTypedRow(null, row);
}

// =============================================================================
// 2. Structural Intermediate Representation (`ir_core`)
// =============================================================================
pub const ContainerFormat = contracts.ir.ContainerFormat;
pub const RegionRole = contracts.ir.RegionRole;
pub const ContainerMetadataRow = contracts.ir.ContainerMetadataRow;
pub const IrRegionRow = contracts.ir.IrRegionRow;

/// Emits a `ContainerMetadataRow` to channel `"container_metadata"`.
pub fn emitContainerMetadata(ctx: TaskContext, row: ContainerMetadataRow) SdkError!void {
    try ctx.emitTypedRow("container_metadata", row);
}

/// Emits an `IrRegionRow` to channel `"ir_regions"`.
pub fn emitIrRegion(ctx: TaskContext, row: IrRegionRow) SdkError!void {
    try ctx.emitTypedRow("ir_regions", row);
}

// =============================================================================
// 3. Deep Media & Sample Table IR (`ir_deep`)
// =============================================================================
pub const IrSampleExtentRow = contracts.ir.IrSampleExtentRow;
pub const IrUnreferencedSlackRow = contracts.ir.IrUnreferencedSlackRow;
pub const IrCodecConfigRow = contracts.ir.IrCodecConfigRow;
pub const IrAttachmentRow = contracts.ir.IrAttachmentRow;
pub const IrExternalRefRow = contracts.ir.IrExternalRefRow;
pub const ByteInterval = contracts.ir.ByteInterval;
pub const computeUnreferencedSlack = contracts.ir.computeUnreferencedSlack;

pub fn emitIrSampleExtent(ctx: TaskContext, row: IrSampleExtentRow) SdkError!void {
    try ctx.emitTypedRow("ir_sample_extents", row);
}

pub fn emitIrUnreferencedSlack(ctx: TaskContext, row: IrUnreferencedSlackRow) SdkError!void {
    try ctx.emitTypedRow("ir_unreferenced_slack", row);
}

pub fn emitIrCodecConfig(ctx: TaskContext, row: IrCodecConfigRow) SdkError!void {
    try ctx.emitTypedRow("ir_codec_configs", row);
}

pub fn emitIrAttachment(ctx: TaskContext, row: IrAttachmentRow) SdkError!void {
    try ctx.emitTypedRow("ir_attachments", row);
}

pub fn emitIrExternalRef(ctx: TaskContext, row: IrExternalRefRow) SdkError!void {
    try ctx.emitTypedRow("ir_external_refs", row);
}

// =============================================================================
// 4. Security Audit & Forensic Findings (`audit`)
// =============================================================================
pub const AuditFindingRow = contracts.audit.AuditFindingRow;

pub fn emitAuditFinding(ctx: TaskContext, row: AuditFindingRow) SdkError!void {
    try ctx.emitTypedRow("audit_findings", row);
}
