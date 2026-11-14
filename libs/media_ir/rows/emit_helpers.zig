const ContainerMetadataRow = @import("container_metadata_row.zig").ContainerMetadataRow;
const IrRegionRow = @import("ir_region_row.zig").IrRegionRow;
const IrSampleExtentRow = @import("ir_sample_extent_row.zig").IrSampleExtentRow;
const IrUnreferencedSlackRow = @import("ir_unreferenced_slack_row.zig").IrUnreferencedSlackRow;
const IrCodecConfigRow = @import("ir_codec_config_row.zig").IrCodecConfigRow;
const IrAttachmentRow = @import("ir_attachment_row.zig").IrAttachmentRow;
const IrExternalRefRow = @import("ir_external_ref_row.zig").IrExternalRefRow;

pub fn emitContainerMetadata(ctx: anytype, row: ContainerMetadataRow) !void {
    try ctx.emitTypedRow(row);
}

pub fn emitIrRegion(ctx: anytype, row: IrRegionRow) !void {
    try ctx.emitTypedRow(row);
}

pub fn emitIrSampleExtent(ctx: anytype, row: IrSampleExtentRow) !void {
    try ctx.emitTypedRow(row);
}

pub fn emitIrUnreferencedSlack(ctx: anytype, row: IrUnreferencedSlackRow) !void {
    try ctx.emitTypedRow(row);
}

pub fn emitIrCodecConfig(ctx: anytype, row: IrCodecConfigRow) !void {
    try ctx.emitTypedRow(row);
}

pub fn emitIrAttachment(ctx: anytype, row: IrAttachmentRow) !void {
    try ctx.emitTypedRow(row);
}

pub fn emitIrExternalRef(ctx: anytype, row: IrExternalRefRow) !void {
    try ctx.emitTypedRow(row);
}
