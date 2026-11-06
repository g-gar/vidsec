const std = @import("std");
const ebml = @import("vidsec_ebml");
const types = @import("../types.zig");

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const EbmlTriageResult = struct {
    element_count: u32,
    root_element_count: u32,
    max_depth: u16,
    cluster_count: u32,
    total_cluster_bytes: u64,
    trailing_slack_bytes: u64,
    doc_type: []const u8,
    doc_type_version: u32,
    verdict: Verdict,
    has_ebml_header: bool,
    has_segment: bool,
    critical_count: u32,
    warning_count: u32,
    flags_csv: []const u8,
};

/// Evaluates Level 1 EBML security policies over parsed elements.
pub fn evaluatePolicy(
    result: ebml.EbmlParseResult,
    file_size: u64,
    flags_buf: []u8,
) EbmlTriageResult {
    var root_count: u32 = 0;
    var max_depth: u16 = 0;
    var critical_count: u32 = 0;
    var warning_count: u32 = 0;

    for (result.elements) |elem| {
        if (elem.parent_id == null) {
            root_count += 1;
        }
        if (elem.depth > max_depth) {
            max_depth = elem.depth;
        }
    }

    var fw = FixedBufWriter.init(flags_buf);
    var first_flag = true;

    for (result.issues) |issue| {
        const is_critical = switch (issue.code) {
            .size_extends_beyond_eof,
            .element_header_truncated,
            .vint_exceeds_max_octets,
            .id_length_exceeds_4_bytes,
            .missing_ebml_header,
            .duplicate_ebml_header,
            => true,
            else => false,
        };

        if (is_critical) {
            critical_count += 1;
        } else {
            warning_count += 1;
        }

        if (!first_flag) {
            fw.writeAll(",") catch {};
        }
        fw.writeAll(issue.code.asText()) catch {};
        first_flag = false;
    }

    // Check for excessive trailing unparsed bytes
    const trailing_slack = if (result.highest_root_end > 0 and result.highest_root_end < file_size)
        file_size - result.highest_root_end
    else
        0;

    if (trailing_slack > (64 * 1024)) {
        warning_count += 1;
        if (!first_flag) {
            fw.writeAll(",") catch {};
        }
        fw.writeAll("EBML_EXCESSIVE_TRAILING_SLACK") catch {};
        first_flag = false;
    }

    var verdict: Verdict = .pass;
    if (critical_count > 0 or !result.has_ebml_header) {
        verdict = .drop;
    } else if (warning_count > 0 or trailing_slack > (64 * 1024)) {
        verdict = .flagged;
    }

    return .{
        .element_count = @intCast(result.elements.len),
        .root_element_count = root_count,
        .max_depth = max_depth,
        .cluster_count = result.cluster_count,
        .total_cluster_bytes = result.total_cluster_bytes,
        .trailing_slack_bytes = trailing_slack,
        .doc_type = result.doc_type,
        .doc_type_version = result.doc_type_version,
        .verdict = verdict,
        .has_ebml_header = result.has_ebml_header,
        .has_segment = result.has_segment,
        .critical_count = critical_count,
        .warning_count = warning_count,
        .flags_csv = fw.written(),
    };
}

pub const ProbeEbmlOutput = struct {
    element_count: u32,
    root_element_count: u32,
    max_depth: u16,
    cluster_count: u32,
    total_cluster_bytes: u64,
    trailing_slack_bytes: u64,
    doc_type: []const u8,
    doc_type_version: u32,
    verdict: []const u8,
    has_ebml_header: bool,
    has_segment: bool,
    flags_csv: []const u8,
};

/// Pure Black Box task for Level 1 EBML structural audit (`analyzer/probe_ebml`).
pub fn auditEbml(alloc: std.mem.Allocator, in: []const u8) !ProbeEbmlOutput {
    const byte_source = ebml.ByteSource.fromSlice(in);
    const parser = ebml.SafeEbmlParser.init(alloc, .{});
    const parse_result = try parser.parse(byte_source);

    const flags_buf = try alloc.alloc(u8, 1024);
    const evaluation = evaluatePolicy(parse_result, in.len, flags_buf);

    return .{
        .element_count = evaluation.element_count,
        .root_element_count = evaluation.root_element_count,
        .max_depth = evaluation.max_depth,
        .cluster_count = evaluation.cluster_count,
        .total_cluster_bytes = evaluation.total_cluster_bytes,
        .trailing_slack_bytes = evaluation.trailing_slack_bytes,
        .doc_type = evaluation.doc_type,
        .doc_type_version = evaluation.doc_type_version,
        .verdict = evaluation.verdict.asText(),
        .has_ebml_header = evaluation.has_ebml_header,
        .has_segment = evaluation.has_segment,
        .flags_csv = evaluation.flags_csv,
    };
}
