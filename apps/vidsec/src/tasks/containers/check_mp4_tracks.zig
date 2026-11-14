const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const isobmff = @import("isobmff");
const media_ir = @import("media_ir");
const common = @import("common.zig");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
};

pub const CheckRow = struct {
    track_count: u64,
    total_samples: u64,
    unreferenced_mdat_slack: u64,
    tracks_valid: bool,
};

pub const OutputsData = struct {
    mp4_tracks_check: CheckRow,
    audit_findings: []const media_ir.AuditFindingRow,
};

pub const Outputs = abi.Channels(OutputsData);

/// Atomic ISOBMFF check: validates `trak` hierarchy, `stco`/`stsz` bounds, and `mdat` slack before IR lowering.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        const parsed = try isobmff.box.SafeBoxParser.init(alloc).parse(source);
        defer parsed.deinit(alloc);

        const inspection = try isobmff.mp4.Mp4Inspector.init(alloc).inspect(source, parsed.boxes);
        defer inspection.deinit(alloc);

        var track_issues = std.ArrayList(isobmff.mp4.Mp4Issue).empty;
        defer track_issues.deinit(alloc);

        for (inspection.issues) |iss| {
            switch (iss.code) {
                .ftyp_unrecognized_brand,
                .ftyp_truncated,
                .esds_tlv_length_overflow,
                .esds_truncated,
                .avcc_invalid_version,
                .avcc_sps_length_overflow,
                .avcc_pps_length_overflow,
                => continue,
                else => try track_issues.append(alloc, iss),
            }
        }

        const findings = try common.collectFindings(alloc, &.{}, &.{}, &.{}, track_issues.items);

        return .{ .data = .{
            .mp4_tracks_check = .{
                .track_count = inspection.tracks.len,
                .total_samples = inspection.total_samples,
                .unreferenced_mdat_slack = inspection.unreferenced_mdat_slack,
                .tracks_valid = track_issues.items.len == 0,
            },
            .audit_findings = findings,
        } };
    }
};

