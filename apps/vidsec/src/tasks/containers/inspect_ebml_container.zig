const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const ebml = @import("ebml");
const media_ir = @import("media_ir");
const common = @import("common.zig");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
};

pub const MkvSummaryRow = struct {
    track_count: u64,
    cluster_count: u64,
    total_cluster_bytes: u64,
    unreferenced_cluster_slack: u64,
    issue_count: u64,
};

pub const OutputsData = struct {
    mkv_summary: MkvSummaryRow,
    audit_findings: []const media_ir.AuditFindingRow,
};

pub const Outputs = abi.Channels(OutputsData);

/// Performs semantic EBML/Matroska inspection (`Info`, `Tracks`, codec configs, cluster metrics)
/// independently of `media_ir` lowering.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        const parser = ebml.ebml.SafeEbmlParser.init(alloc, .{});
        const parsed = try parser.parse(source);
        defer parsed.deinit(alloc);

        const inspection = try ebml.mkv.MkvInspector.init(alloc).inspect(source, parsed.elements);

        const findings = try common.collectFindings(
            alloc,
            &.{},
            &.{},
            &.{},
            inspection.issues,
        );

        return .{ .data = .{
            .mkv_summary = .{
                .track_count = inspection.tracks.len,
                .cluster_count = inspection.cluster_count,
                .total_cluster_bytes = inspection.total_cluster_bytes,
                .unreferenced_cluster_slack = inspection.unreferenced_cluster_slack,
                .issue_count = inspection.issues.len,
            },
            .audit_findings = findings,
        } };
    }
};

