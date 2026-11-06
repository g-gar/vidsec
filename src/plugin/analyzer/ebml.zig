const std = @import("std");
const abi = @import("vidsec_abi");
const ebml = @import("vidsec_ebml");
const types = @import("types.zig");

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

/// Evaluates security policy over raw parse results from the EBML parser.
pub fn evaluateEbmlPolicy(
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

/// Converts an `abi.BoundedStreamReader` into an `ebml.ByteSource`.
pub fn makeByteSource(stream: abi.BoundedStreamReader) ebml.ByteSource {
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

pub const ProbeEbmlInputs = struct {
    stream: abi.BoundedStreamReader,
    emit_elements: bool = false,
    recurse_clusters: bool = false,
};

/// C-ABI task implementation for `triage/probe_ebml`.
pub fn runProbeEbml(ctx: abi.TaskContext, inputs: ProbeEbmlInputs) abi.SdkError!abi.TaskStatus_ABI {
    const stream = inputs.stream;
    const emit_elements = inputs.emit_elements;
    const recurse_clusters = inputs.recurse_clusters;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const byte_source = makeByteSource(stream);

    const parser = ebml.SafeEbmlParser.init(allocator, .{
        .recurse_clusters = recurse_clusters,
    });

    const parse_result = parser.parse(byte_source) catch |err| {
        ctx.logError("Failed to parse EBML grammar");
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .fatal_error,
        };
    };

    var flags_buf: [1024]u8 = undefined;
    const evaluation = evaluateEbmlPolicy(parse_result, stream.len(), &flags_buf);

    try ctx.emitRow("ebml_triage", &.{
        abi.NamedField_ABI.init("element_count", abi.Value_ABI.fromInt(@intCast(evaluation.element_count))),
        abi.NamedField_ABI.init("root_element_count", abi.Value_ABI.fromInt(@intCast(evaluation.root_element_count))),
        abi.NamedField_ABI.init("max_depth", abi.Value_ABI.fromInt(@intCast(evaluation.max_depth))),
        abi.NamedField_ABI.init("cluster_count", abi.Value_ABI.fromInt(@intCast(evaluation.cluster_count))),
        abi.NamedField_ABI.init("total_cluster_bytes", abi.Value_ABI.fromInt(@intCast(evaluation.total_cluster_bytes))),
        abi.NamedField_ABI.init("trailing_slack_bytes", abi.Value_ABI.fromInt(@intCast(evaluation.trailing_slack_bytes))),
        abi.NamedField_ABI.init("doc_type", abi.Value_ABI.fromText(evaluation.doc_type)),
        abi.NamedField_ABI.init("doc_type_version", abi.Value_ABI.fromInt(@intCast(evaluation.doc_type_version))),
        abi.NamedField_ABI.init("verdict", abi.Value_ABI.fromInt(evaluation.verdict.toInt())),
        abi.NamedField_ABI.init("has_ebml_header", abi.Value_ABI.fromBool(evaluation.has_ebml_header)),
        abi.NamedField_ABI.init("has_segment", abi.Value_ABI.fromBool(evaluation.has_segment)),
        abi.NamedField_ABI.init("flags_csv", abi.Value_ABI.fromText(evaluation.flags_csv)),
    });

    if (emit_elements) {
        for (parse_result.elements, 0..) |elem, idx| {
            var hex_buf: [16]u8 = undefined;
            const hex_id = std.fmt.bufPrint(&hex_buf, "0x{X:0>2}", .{elem.id}) catch "0x00";

            const parent_val = if (elem.parent_id) |pid|
                abi.Value_ABI.fromInt(@intCast(pid))
            else
                abi.Value_ABI.nullVal();

            try ctx.emitRow("ebml_elements", &.{
                abi.NamedField_ABI.init("element_id", abi.Value_ABI.fromInt(@intCast(idx))),
                abi.NamedField_ABI.init("parent_element_id", parent_val),
                abi.NamedField_ABI.init("depth", abi.Value_ABI.fromInt(@intCast(elem.depth))),
                abi.NamedField_ABI.init("ebml_id_hex", abi.Value_ABI.fromText(hex_id)),
                abi.NamedField_ABI.init("role", abi.Value_ABI.fromText(elem.role.asText())),
                abi.NamedField_ABI.init("header_offset", abi.Value_ABI.fromInt(@intCast(elem.header.offset))),
                abi.NamedField_ABI.init("payload_offset", abi.Value_ABI.fromInt(@intCast(elem.header.payloadOffset()))),
                abi.NamedField_ABI.init("data_size", abi.Value_ABI.fromInt(@intCast(elem.header.data_size))),
                abi.NamedField_ABI.init("total_size", abi.Value_ABI.fromInt(@intCast(elem.header.totalSize()))),
                abi.NamedField_ABI.init("is_unknown_size", abi.Value_ABI.fromBool(elem.header.is_unknown_size)),
                abi.NamedField_ABI.init("child_count", abi.Value_ABI.fromInt(@intCast(elem.child_count))),
            });
        }
    }

    if (evaluation.verdict == .pass) {
        ctx.logInfoFmt("Passed EBML structural triage: {d} elements, doctype={s} v{d}, {d} clusters ({d} bytes)", .{
            evaluation.element_count,
            evaluation.doc_type,
            evaluation.doc_type_version,
            evaluation.cluster_count,
            evaluation.total_cluster_bytes,
        });
    } else if (evaluation.verdict == .flagged) {
        ctx.logWarnFmt("EBML structural triage FLAGGED: {s}", .{evaluation.flags_csv});
    } else {
        ctx.logErrorFmt("EBML structural triage REJECTED/DROP: {s}", .{evaluation.flags_csv});
    }

    return .ok;
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

/// Modern pure Black Box task for Level 1 EBML structural audit (`analyzer/probe_ebml`).
pub fn probeEbmlTask(alloc: std.mem.Allocator, in: []const u8) !ProbeEbmlOutput {
    const byte_source = ebml.ByteSource.fromSlice(in);
    const parser = ebml.SafeEbmlParser.init(alloc, .{});
    const parse_result = try parser.parse(byte_source);

    const flags_buf = try alloc.alloc(u8, 1024);
    const evaluation = evaluateEbmlPolicy(parse_result, in.len, flags_buf);

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
