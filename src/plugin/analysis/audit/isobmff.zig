const std = @import("std");
const isobmff = @import("vidsec_isobmff");
const types = @import("../types.zig");

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const FourCC = isobmff.FourCC;
pub const ParsedBox = isobmff.ParsedBox;
pub const ParserIssue = isobmff.ParserIssue;
pub const ParserIssueCode = isobmff.ParserIssueCode;
pub const BoxRole = isobmff.BoxRole;

/// High-level evaluation of ISOBMFF structural integrity and security policy.
pub const IsobmffTriageResult = struct {
    box_count: u32,
    root_box_count: u32,
    max_depth: u16,
    mdat_count: u32,
    total_mdat_bytes: u64,
    trailing_slack_bytes: u64,
    verdict: Verdict,
    has_ftyp: bool,
    has_moov: bool,
    ftyp_count: u32,
    moov_count: u32,
    critical_issues_count: u32,
    warning_issues_count: u32,
    flags_csv: []const u8,
};

/// Evaluates security policy over raw parse results from the pure ISOBMFF parser.
pub fn evaluatePolicy(
    result: isobmff.ParseResult,
    file_size: u64,
    flags_buf: []u8,
) IsobmffTriageResult {
    var root_box_count: u32 = 0;
    var max_depth: u16 = 0;
    var mdat_count: u32 = 0;
    var total_mdat_bytes: u64 = 0;
    var critical_count: u32 = 0;
    var warning_count: u32 = 0;

    for (result.boxes) |box| {
        if (box.parent_id == null) {
            root_box_count += 1;
        }
        if (box.depth > max_depth) {
            max_depth = box.depth;
        }
        if (box.header.fourcc.equals(isobmff.types.BOX_MDAT)) {
            mdat_count += 1;
            total_mdat_bytes += box.header.size;
        }
    }

    var fw = FixedBufWriter.init(flags_buf);
    var first_flag = true;

    for (result.issues) |issue| {
        const is_critical = switch (issue.code) {
            .box_size_invalid,
            .box_size_overflow,
            .large_size_invalid,
            .truncated_header,
            .multiple_ftyp,
            .missing_moov,
            .multiple_moov,
            .container_cycle_or_overlap,
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

    const trailing_slack: u64 = if (result.highest_root_end > 0 and result.highest_root_end < file_size)
        file_size - result.highest_root_end
    else
        0;

    if (trailing_slack > 64) {
        warning_count += 1;
        if (!first_flag) {
            fw.writeAll(",") catch {};
        }
        fw.writeAll("ISOBMFF_ORPHANED_TRAILING_DATA") catch {};
    }

    var verdict: Verdict = .pass;
    if (critical_count > 0 or !result.has_moov or result.ftyp_count > 1 or result.moov_count > 1) {
        verdict = .drop;
    } else if (warning_count > 0) {
        verdict = .flagged;
    }

    return .{
        .box_count = @intCast(result.boxes.len),
        .root_box_count = root_box_count,
        .max_depth = max_depth,
        .mdat_count = mdat_count,
        .total_mdat_bytes = total_mdat_bytes,
        .trailing_slack_bytes = trailing_slack,
        .verdict = verdict,
        .has_ftyp = result.has_ftyp,
        .has_moov = result.has_moov,
        .ftyp_count = result.ftyp_count,
        .moov_count = result.moov_count,
        .critical_issues_count = critical_count,
        .warning_issues_count = warning_count,
        .flags_csv = fw.written(),
    };
}

pub const ProbeIsobmffOutput = struct {
    box_count: u32,
    root_box_count: u32,
    max_depth: u16,
    mdat_count: u32,
    total_mdat_bytes: u64,
    trailing_slack_bytes: u64,
    verdict: []const u8,
    has_ftyp: bool,
    has_moov: bool,
    flags_csv: []const u8,
};

/// Pure Black Box task for Level 1 ISOBMFF structural audit (`analyzer/probe_isobmff`).
pub fn auditIsobmff(alloc: std.mem.Allocator, in: []const u8) !ProbeIsobmffOutput {
    const byte_source = isobmff.ByteSource.fromSlice(in);
    const parser = isobmff.SafeBoxParser.init(alloc);
    const parse_result = try parser.parse(byte_source);

    const flags_buf = try alloc.alloc(u8, 1024);
    const triage_res = evaluatePolicy(parse_result, in.len, flags_buf);

    return .{
        .box_count = triage_res.box_count,
        .root_box_count = triage_res.root_box_count,
        .max_depth = triage_res.max_depth,
        .mdat_count = triage_res.mdat_count,
        .total_mdat_bytes = triage_res.total_mdat_bytes,
        .trailing_slack_bytes = triage_res.trailing_slack_bytes,
        .verdict = triage_res.verdict.asText(),
        .has_ftyp = triage_res.has_ftyp,
        .has_moov = triage_res.has_moov,
        .flags_csv = triage_res.flags_csv,
    };
}
