const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const riff = @import("riff");
const media_ir = @import("media_ir");
const common = @import("common.zig");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
};

pub const CheckRow = struct {
    form_type: []const u8,
    root_size: u64,
    movi_bytes: u64,
    junk_bytes: u64,
    trailing_slack_bytes: u64,
    riff_valid: bool,
};

pub const OutputsData = struct {
    riff_chunks_check: CheckRow,
    audit_findings: []const media_ir.AuditFindingRow,
};

pub const Outputs = abi.Channels(OutputsData);

const inline_checks = [_]media_ir.common.InLineCheck{
    .{ .run_fn = riff.riff.checks.checkChunkOverflow },
};

/// Atomic RIFF/AVI check: validates `form_type`, chunk bounds, `movi`/`JUNK` totals, and trailing slack before IR lowering.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        var diagnostics = media_ir.common.DiagnosticList.init();
        defer diagnostics.deinit(alloc);

        const parsed = try riff.riff.SafeRiffParser.init(alloc, .{}).parseWithDiagnostics(source, &inline_checks, &diagnostics);
        defer parsed.deinit(alloc);

        const findings = try common.collectFindings(alloc, &.{}, parsed.issues, diagnostics.items.items, &.{});

        return .{ .data = .{
            .riff_chunks_check = .{
                .form_type = try alloc.dupe(u8, &parsed.form_type.bytes),
                .root_size = parsed.root_size,
                .movi_bytes = parsed.movi_bytes,
                .junk_bytes = parsed.junk_bytes,
                .trailing_slack_bytes = parsed.trailing_slack_bytes,
                .riff_valid = findings.len == 0,
            },
            .audit_findings = findings,
        } };
    }
};

