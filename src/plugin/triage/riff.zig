const std = @import("std");
const abi = @import("vidsec_abi");
const riff = @import("vidsec_riff");
const types = @import("types.zig");

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const RiffTriageEvaluation = struct {
    verdict: Verdict,
    critical_count: u32,
    warning_count: u32,
    flags_csv: []const u8,
};

/// Evaluates security policy over RIFF container parse results.
pub fn evaluateRiffPolicy(
    result: riff.RiffParseResult,
    file_size: u64,
    flags_buf: []u8,
) RiffTriageEvaluation {
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

    if (file_size > 0 and result.junk_bytes > (file_size / 2)) {
        warning_count += 1;
        if (!first_flag) {
            fw.writeAll(",") catch {};
        }
        fw.writeAll("RIFF_EXCESSIVE_JUNK_PADDING") catch {};
        first_flag = false;
    }

    var verdict: Verdict = .pass;
    if (critical_count > 0 or result.chunks.len == 0) {
        verdict = .drop;
    } else if (warning_count > 0 or result.trailing_slack_bytes > (64 * 1024)) {
        verdict = .flagged;
    }

    return .{
        .verdict = verdict,
        .critical_count = critical_count,
        .warning_count = warning_count,
        .flags_csv = fw.written(),
    };
}

/// Converts an `abi.BoundedStreamReader` into a `riff.ByteSource`.
pub fn makeByteSource(stream: abi.BoundedStreamReader) riff.ByteSource {
    const StreamContext = struct {
        reader: abi.BoundedStreamReader,

        fn readAt(ctx_ptr: *const anyopaque, buf: []u8, offset: u64) anyerror!usize {
            const self = @as(*const @This(), @ptrCast(@alignCast(ctx_ptr)));
            self.reader.readAt(offset, buf) catch return 0;
            return buf.len;
        }
    };

    const S = struct {
        var shared_ctx: StreamContext = undefined;
    };
    S.shared_ctx = .{ .reader = stream };

    return .{
        .ctx = @ptrCast(&S.shared_ctx),
        .read_at_fn = StreamContext.readAt,
        .file_size = stream.len(),
    };
}

/// C-ABI task implementation for `triage/probe_riff`.
pub fn runProbeRiff(ctx: abi.TaskContext) abi.SdkError!abi.TaskStatus_ABI {
    const stream = ctx.streamReader();
    const emit_chunks = try ctx.getParamBool("emit_chunks", false);
    const recurse_movi = try ctx.getParamBool("recurse_movi", false);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const byte_source = makeByteSource(stream);

    const parser = riff.SafeRiffParser.init(allocator, .{
        .recurse_movi = recurse_movi,
    });

    const parse_result = parser.parse(byte_source) catch |err| {
        ctx.logError("Failed to parse RIFF container structure");
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .fatal_error,
        };
    };

    var root_chunk_count: u32 = 0;
    var max_depth: u16 = 0;
    for (parse_result.chunks) |c| {
        if (c.parent_id == null) root_chunk_count += 1;
        if (c.depth > max_depth) max_depth = c.depth;
    }

    var flags_buf: [1024]u8 = undefined;
    const evaluation = evaluateRiffPolicy(parse_result, stream.len(), &flags_buf);

    // 1. Emit primary RIFF triage row
    try ctx.emitRow("riff_triage", &.{
        abi.NamedField_ABI.init("chunk_count", abi.Value_ABI.fromInt(@intCast(parse_result.chunks.len))),
        abi.NamedField_ABI.init("root_chunk_count", abi.Value_ABI.fromInt(@intCast(root_chunk_count))),
        abi.NamedField_ABI.init("max_depth", abi.Value_ABI.fromInt(@intCast(max_depth))),
        abi.NamedField_ABI.init("form_type", abi.Value_ABI.fromText(&parse_result.form_type.bytes)),
        abi.NamedField_ABI.init("root_size", abi.Value_ABI.fromInt(@intCast(parse_result.root_size))),
        abi.NamedField_ABI.init("movi_bytes", abi.Value_ABI.fromInt(@intCast(parse_result.movi_bytes))),
        abi.NamedField_ABI.init("junk_bytes", abi.Value_ABI.fromInt(@intCast(parse_result.junk_bytes))),
        abi.NamedField_ABI.init("trailing_slack_bytes", abi.Value_ABI.fromInt(@intCast(parse_result.trailing_slack_bytes))),
        abi.NamedField_ABI.init("verdict", abi.Value_ABI.fromInt(evaluation.verdict.toInt())),
        abi.NamedField_ABI.init("flags_csv", abi.Value_ABI.fromText(evaluation.flags_csv)),
    });

    // 2. Optionally emit chunks table
    if (emit_chunks) {
        for (parse_result.chunks, 0..) |c, idx| {
            const parent_val = if (c.parent_id) |pid|
                abi.Value_ABI.fromInt(@intCast(pid))
            else
                abi.Value_ABI.nullVal();

            try ctx.emitRow("riff_chunks", &.{
                abi.NamedField_ABI.init("chunk_id", abi.Value_ABI.fromInt(@intCast(idx))),
                abi.NamedField_ABI.init("parent_chunk_id", parent_val),
                abi.NamedField_ABI.init("depth", abi.Value_ABI.fromInt(@intCast(c.depth))),
                abi.NamedField_ABI.init("fourcc", abi.Value_ABI.fromText(&c.header.fourcc.bytes)),
                abi.NamedField_ABI.init("role", abi.Value_ABI.fromText(c.role.asText())),
                abi.NamedField_ABI.init("header_offset", abi.Value_ABI.fromInt(@intCast(c.header.offset))),
                abi.NamedField_ABI.init("payload_offset", abi.Value_ABI.fromInt(@intCast(c.header.payloadOffset()))),
                abi.NamedField_ABI.init("data_size", abi.Value_ABI.fromInt(@intCast(c.header.size))),
                abi.NamedField_ABI.init("total_size", abi.Value_ABI.fromInt(@intCast(c.header.totalSize()))),
                abi.NamedField_ABI.init("is_padded", abi.Value_ABI.fromBool(c.header.is_padded)),
                abi.NamedField_ABI.init("child_count", abi.Value_ABI.fromInt(@intCast(c.child_count))),
            });
        }
    }

    if (evaluation.verdict == .pass) {
        ctx.logInfo("triage/probe_riff: PASS");
    } else if (evaluation.verdict == .flagged) {
        ctx.logWarn(evaluation.flags_csv);
    } else {
        ctx.logError(evaluation.flags_csv);
    }

    return .ok;
}
