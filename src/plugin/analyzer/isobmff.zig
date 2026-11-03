const std = @import("std");
const abi = @import("vidsec_abi");
const isobmff = @import("vidsec_isobmff");
const types = @import("types.zig");

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
        // Classify severity according to triage policy:
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

/// Adapter converting an `abi.BoundedStreamReader` into an `isobmff.ByteSource`.
pub fn makeByteSource(stream: abi.BoundedStreamReader) isobmff.ByteSource {
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

pub const ProbeIsobmffInputs = struct {
    stream: abi.BoundedStreamReader,
    emit_boxes: bool = false,
    allow_gaps: bool = false,
    max_gap_tolerance_bytes: u64 = 0,
    allow_trailing_data: bool = false,
    max_depth: u8 = 8,
    strict_order: bool = true,
};

/// C-ABI task implementation for `triage/probe_isobmff`.
pub fn runProbeIsobmff(ctx: abi.TaskContext, inputs: ProbeIsobmffInputs) abi.SdkError!abi.TaskStatus_ABI {
    const stream = inputs.stream;
    const file_size = stream.len();
    const emit_boxes = inputs.emit_boxes;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const byte_source = makeByteSource(stream);
    const parser = isobmff.SafeBoxParser.init(allocator);

    const parse_result = parser.parse(byte_source) catch |err| {
        ctx.logError("Failed to parse ISOBMFF container stream");
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .fatal_error,
        };
    };

    var flags_buf: [1024]u8 = undefined;
    const triage_res = evaluatePolicy(parse_result, file_size, &flags_buf);

    // 1. Emit primary triage summary row into `isobmff_triage`
    try ctx.emitRow("isobmff_triage", &.{
        abi.NamedField_ABI.init("box_count", abi.Value_ABI.fromInt(@intCast(triage_res.box_count))),
        abi.NamedField_ABI.init("root_box_count", abi.Value_ABI.fromInt(@intCast(triage_res.root_box_count))),
        abi.NamedField_ABI.init("max_depth", abi.Value_ABI.fromInt(@intCast(triage_res.max_depth))),
        abi.NamedField_ABI.init("mdat_count", abi.Value_ABI.fromInt(@intCast(triage_res.mdat_count))),
        abi.NamedField_ABI.init("total_mdat_bytes", abi.Value_ABI.fromInt(@intCast(triage_res.total_mdat_bytes))),
        abi.NamedField_ABI.init("trailing_slack_bytes", abi.Value_ABI.fromInt(@intCast(triage_res.trailing_slack_bytes))),
        abi.NamedField_ABI.init("verdict", abi.Value_ABI.fromInt(triage_res.verdict.toInt())),
        abi.NamedField_ABI.init("has_ftyp", abi.Value_ABI.fromBool(triage_res.has_ftyp)),
        abi.NamedField_ABI.init("has_moov", abi.Value_ABI.fromBool(triage_res.has_moov)),
        abi.NamedField_ABI.init("flags_csv", abi.Value_ABI.fromText(triage_res.flags_csv)),
    });

    // 2. Optionally emit individual box rows into `isobmff_boxes`
    if (emit_boxes) {
        for (parse_result.boxes) |b| {
            var fourcc_buf: [4]u8 = b.header.fourcc.bytes;
            const parent_val = if (b.parent_id) |pid|
                abi.Value_ABI.fromInt(@intCast(pid))
            else
                abi.Value_ABI.nullVal();

            try ctx.emitRow("isobmff_boxes", &.{
                abi.NamedField_ABI.init("box_id", abi.Value_ABI.fromInt(@intCast(b.id))),
                abi.NamedField_ABI.init("parent_box_id", parent_val),
                abi.NamedField_ABI.init("depth", abi.Value_ABI.fromInt(@intCast(b.depth))),
                abi.NamedField_ABI.init("fourcc", abi.Value_ABI.fromText(&fourcc_buf)),
                abi.NamedField_ABI.init("role", abi.Value_ABI.fromText(b.role.asText())),
                abi.NamedField_ABI.init("header_offset", abi.Value_ABI.fromInt(@intCast(b.header.offset))),
                abi.NamedField_ABI.init("payload_offset", abi.Value_ABI.fromInt(@intCast(b.header.payloadOffset()))),
                abi.NamedField_ABI.init("box_size", abi.Value_ABI.fromInt(@intCast(b.header.size))),
                abi.NamedField_ABI.init("is_extended_size", abi.Value_ABI.fromBool(b.header.is_extended_size)),
                abi.NamedField_ABI.init("is_full_box", abi.Value_ABI.fromBool(b.is_full_box)),
                abi.NamedField_ABI.init("version", abi.Value_ABI.fromInt(@intCast(b.version))),
                abi.NamedField_ABI.init("flags", abi.Value_ABI.fromInt(@intCast(b.flags))),
                abi.NamedField_ABI.init("child_count", abi.Value_ABI.fromInt(@intCast(b.child_count))),
            });
        }
    }

    if (triage_res.verdict == .pass) {
        ctx.logInfoFmt("Passed ISOBMFF structural triage: {d} boxes, {d} mdat ({d} bytes)", .{
            triage_res.box_count,
            triage_res.mdat_count,
            triage_res.total_mdat_bytes,
        });
    } else if (triage_res.verdict == .flagged) {
        ctx.logWarnFmt("ISOBMFF structural triage FLAGGED: {s}", .{triage_res.flags_csv});
    } else {
        ctx.logErrorFmt("ISOBMFF structural triage REJECTED/DROP: {s}", .{triage_res.flags_csv});
    }

    return .ok;
}
