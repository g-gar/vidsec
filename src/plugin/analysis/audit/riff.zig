const std = @import("std");
const riff = @import("vidsec_riff");
const types = @import("../types.zig");

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const RiffTriageEvaluation = struct {
    verdict: Verdict,
    critical_count: u32,
    warning_count: u32,
    flags_csv: []const u8,
};

/// Evaluates Level 1 RIFF security policies over parsed chunks.
pub fn evaluatePolicy(
    result: riff.RiffParseResult,
    file_size: u64,
    flags_buf: []u8,
) RiffTriageEvaluation {
    _ = file_size;
    var fw = FixedBufWriter.init(flags_buf);
    var critical_count: u32 = 0;
    var warning_count: u32 = 0;
    var first_flag = true;

    for (result.issues) |issue| {
        const is_critical = switch (issue.code) {
            .riff_magic_invalid,
            .root_size_too_small,
            .chunk_size_overflow,
            .truncated_chunk_header,
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

    if (result.trailing_slack_bytes > (64 * 1024)) {
        warning_count += 1;
        if (!first_flag) {
            fw.writeAll(",") catch {};
        }
        fw.writeAll("RIFF_EXCESSIVE_TRAILING_SLACK") catch {};
        first_flag = false;
    }

    const verdict: Verdict = if (critical_count > 0)
        .drop
    else if (warning_count > 0)
        .flagged
    else
        .pass;

    return .{
        .verdict = verdict,
        .critical_count = critical_count,
        .warning_count = warning_count,
        .flags_csv = fw.written(),
    };
}

pub const ProbeRiffOutput = struct {
    chunk_count: u32,
    root_chunk_count: u32,
    max_depth: u16,
    form_type: []const u8,
    root_size: u64,
    movi_bytes: u64,
    junk_bytes: u64,
    trailing_slack_bytes: u64,
    verdict: []const u8,
    flags_csv: []const u8,
};

/// Pure Black Box task for Level 1 RIFF structural audit (`analyzer/probe_riff`).
pub fn auditRiff(alloc: std.mem.Allocator, in: []const u8) !ProbeRiffOutput {
    const byte_source = riff.ByteSource.fromSlice(in);
    const parser = riff.SafeRiffParser.init(alloc, .{});
    const parse_result = try parser.parse(byte_source);

    const flags_buf = try alloc.alloc(u8, 1024);
    const evaluation = evaluatePolicy(parse_result, in.len, flags_buf);

    var root_chunk_count: u32 = 0;
    var max_depth: u16 = 0;
    for (parse_result.chunks) |c| {
        if (c.parent_id == null) root_chunk_count += 1;
        if (c.depth > max_depth) max_depth = c.depth;
    }

    const form = try alloc.dupe(u8, &parse_result.form_type.bytes);

    return .{
        .chunk_count = @intCast(parse_result.chunks.len),
        .root_chunk_count = root_chunk_count,
        .max_depth = max_depth,
        .form_type = form,
        .root_size = parse_result.root_size,
        .movi_bytes = parse_result.movi_bytes,
        .junk_bytes = parse_result.junk_bytes,
        .trailing_slack_bytes = parse_result.trailing_slack_bytes,
        .verdict = evaluation.verdict.asText(),
        .flags_csv = evaluation.flags_csv,
    };
}
