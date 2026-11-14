const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const ebml = @import("ebml");
const media_ir = @import("media_ir");
const common = @import("common.zig");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
};

pub const CheckRow = struct {
    has_ebml_header: bool,
    has_segment: bool,
    doc_type: []const u8,
    cluster_count: u64,
    ebml_valid: bool,
};

pub const OutputsData = struct {
    ebml_header_check: CheckRow,
    audit_findings: []const media_ir.AuditFindingRow,
};

pub const Outputs = abi.Channels(OutputsData);

const inline_checks = [_]media_ir.common.InLineCheck{
    .{ .run_fn = ebml.ebml.checks.checkElementSize },
};

/// Atomic EBML check: validates EBML header, `Segment`, `doc_type`, and VINT element sizes before IR lowering.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        var diagnostics = media_ir.common.DiagnosticList.init();
        defer diagnostics.deinit(alloc);

        const parsed = try ebml.ebml.SafeEbmlParser.init(alloc, .{}).parseWithDiagnostics(source, &inline_checks, &diagnostics);
        defer parsed.deinit(alloc);

        const doc_type = if (parsed.doc_type.len > 0) try alloc.dupe(u8, parsed.doc_type) else "unknown";
        const findings = try common.collectFindings(alloc, &.{}, parsed.issues, diagnostics.items.items, &.{});
        const valid = parsed.has_ebml_header and parsed.has_segment and findings.len == 0;

        return .{ .data = .{
            .ebml_header_check = .{
                .has_ebml_header = parsed.has_ebml_header,
                .has_segment = parsed.has_segment,
                .doc_type = doc_type,
                .cluster_count = parsed.cluster_count,
                .ebml_valid = valid,
            },
            .audit_findings = findings,
        } };
    }
};

