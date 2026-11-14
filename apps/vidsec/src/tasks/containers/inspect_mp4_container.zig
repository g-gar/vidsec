const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const isobmff = @import("isobmff");
const media_ir = @import("media_ir");
const common = @import("common.zig");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
};

pub const Mp4SummaryRow = struct {
    major_brand: []const u8,
    track_count: u64,
    total_samples: u64,
    total_sample_bytes: u64,
    total_mdat_bytes: u64,
    unreferenced_mdat_slack: u64,
    issue_count: u64,
};

pub const OutputsData = struct {
    mp4_summary: Mp4SummaryRow,
    audit_findings: []const media_ir.AuditFindingRow,
};

pub const Outputs = abi.Channels(OutputsData);

/// Performs semantic MP4 inspection (`ftyp`, `trak`, `stbl`, `avcC`/`esds`, `mdat` slack)
/// independently of `media_ir` lowering.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        const parser = isobmff.box.SafeBoxParser.init(alloc);
        const parsed = try parser.parse(source);
        defer parsed.deinit(alloc);

        const inspection = try isobmff.mp4.Mp4Inspector.init(alloc).inspect(source, parsed.boxes);
        defer inspection.deinit(alloc);

        const major_brand = if (inspection.ftyp) |f|
            try alloc.dupe(u8, &f.major_brand.bytes)
        else
            "none";

        const findings = try common.collectFindings(
            alloc,
            &.{},
            &.{},
            &.{},
            inspection.issues,
        );

        return .{ .data = .{
            .mp4_summary = .{
                .major_brand = major_brand,
                .track_count = inspection.tracks.len,
                .total_samples = inspection.total_samples,
                .total_sample_bytes = inspection.total_sample_bytes,
                .total_mdat_bytes = inspection.total_mdat_bytes,
                .unreferenced_mdat_slack = inspection.unreferenced_mdat_slack,
                .issue_count = inspection.issues.len,
            },
            .audit_findings = findings,
        } };
    }
};

