const std = @import("std");

pub const container_format = @import("container_format.zig");
pub const region_role = @import("region_role.zig");
pub const track_type = @import("track_type.zig");
pub const byte_stream = @import("byte_stream.zig");
pub const slice_stream = @import("slice_stream.zig");
pub const region = @import("region.zig");
pub const track = @import("track.zig");
pub const sample_extent = @import("sample_extent.zig");
pub const container_ir = @import("container_ir.zig");
pub const rows = @import("rows/mod.zig");

// Canonical re-exports of domain types and entities
pub const ContainerFormat = container_format.ContainerFormat;
pub const RegionRole = region_role.RegionRole;
pub const TrackType = track_type.TrackType;
pub const ByteStream = byte_stream.ByteStream;
pub const SliceStream = slice_stream.SliceStream;
pub const Region = region.Region;
pub const Track = track.Track;
pub const SampleExtent = sample_extent.SampleExtent;
pub const ContainerIR = container_ir.ContainerIR;

// Pipeline relational row representations
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

test {
    std.testing.refAllDecls(@This());
}
