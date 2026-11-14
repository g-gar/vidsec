const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const riff = @import("riff");
const media_ir = @import("media_ir");
const common = @import("common.zig");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
};

pub const RiffSummaryRow = struct {
    form_type: []const u8,
    root_size: u64,
    movi_bytes: u64,
    junk_bytes: u64,
    trailing_slack_bytes: u64,
    issue_count: u64,
};

pub const OutputsData = struct {
    riff_summary: RiffSummaryRow,
    audit_findings: []const media_ir.AuditFindingRow,
};

pub const Outputs = abi.Channels(OutputsData);

/// Performs RIFF/AVI format inspection (`form_type`, `movi`/`JUNK` byte totals, trailing slack)
/// independently of `media_ir` lowering.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        const parser = riff.riff.SafeRiffParser.init(alloc, .{});
        const parsed = try parser.parse(source);
        defer parsed.deinit(alloc);

        const findings = try common.collectFindings(
            alloc,
            &.{},
            parsed.issues,
            &.{},
            &.{},
        );

        return .{ .data = .{
            .riff_summary = .{
                .form_type = try alloc.dupe(u8, &parsed.form_type.bytes),
                .root_size = parsed.root_size,
                .movi_bytes = parsed.movi_bytes,
                .junk_bytes = parsed.junk_bytes,
                .trailing_slack_bytes = parsed.trailing_slack_bytes,
                .issue_count = parsed.issues.len,
            },
            .audit_findings = findings,
        } };
    }
};

