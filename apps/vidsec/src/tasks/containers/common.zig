const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const media_ir = @import("media_ir");

/// Common inputs for Stage 1 container parsing and lowering tasks.
pub const ContainerInputs = struct {
    stream: abi.BoundedStreamReader,
    true_magic_kind: i64 = 0,
    identified_format: []const u8 = "unknown",
};

/// Common outputs emitted by Stage 1 container lowering tasks (`pipeline.yaml`).
pub const ContainerOutputsData = struct {
    container_metadata: media_ir.ContainerMetadataRow,
    ir_regions: []const media_ir.IrRegionRow,
    audit_findings: []const media_ir.AuditFindingRow,
};

pub const ContainerOutputs = abi.Channels(ContainerOutputsData);

/// Adapts a `BoundedStreamReader` into a `media_ir.common.ByteSource` without loading the stream into RAM.
pub fn streamToByteSource(reader: *const abi.BoundedStreamReader) media_ir.common.ByteSource {
    const Wrapper = struct {
        fn readAt(ctx_ptr: *const anyopaque, buf: []u8, offset: u64) anyerror!usize {
            const stream_ptr: *const abi.BoundedStreamReader = @ptrCast(@alignCast(ctx_ptr));
            try stream_ptr.readAt(offset, buf);
            return buf.len;
        }
    };

    return .{
        .ctx = @ptrCast(reader),
        .read_at_fn = Wrapper.readAt,
        .file_size = reader.len(),
    };
}

/// Converts parser `Region` slices into `media_ir.RegionInput` slices with UTF-8 safe tags.
pub fn regionsToInputs(alloc: Allocator, regions: []const media_ir.common.Region) ![]media_ir.RegionInput {
    var out = try alloc.alloc(media_ir.RegionInput, regions.len);
    for (regions, 0..) |reg, i| {
        const tag = if (isPrintableFourCC(reg.tag))
            try alloc.dupe(u8, &reg.tag)
        else
            try std.fmt.allocPrint(alloc, "0x{x:0>8}", .{std.mem.readInt(u32, &reg.tag, .big)});

        out[i] = .{
            .id = @intCast(reg.id),
            .parent_id = if (reg.parent_id) |pid| @as(i64, @intCast(pid)) else null,
            .tag = tag,
            .role = reg.role.asText(),
            .header_offset = @intCast(reg.header_offset),
            .payload_offset = @intCast(reg.payload_offset),
            .size = @intCast(reg.size),
        };
    }
    return out;
}

/// Converts parser-specific issues, in-line diagnostics, and inspector issues, merging them with `overflow_findings`.
pub fn collectFindings(
    alloc: Allocator,
    overflow_findings: []const media_ir.AuditFindingRow,
    parser_issues: anytype,
    diagnostics: []const media_ir.common.DiagnosticFinding,
    inspector_issues: anytype,
) ![]const media_ir.AuditFindingRow {
    var list = std.ArrayList(media_ir.AuditFindingRow).empty;
    errdefer list.deinit(alloc);

    try list.appendSlice(alloc, overflow_findings);
    try appendIssueSlice(alloc, &list, parser_issues);
    try appendDiagnostics(alloc, &list, diagnostics);
    try appendIssueSlice(alloc, &list, inspector_issues);

    return try list.toOwnedSlice(alloc);
}

fn appendDiagnostics(
    alloc: Allocator,
    list: *std.ArrayList(media_ir.AuditFindingRow),
    diagnostics: []const media_ir.common.DiagnosticFinding,
) !void {
    for (diagnostics) |diag| {
        const sev: i64 = switch (diag.severity) {
            .info => 0,
            .warning => 2,
            .critical => 4,
        };
        try list.append(alloc, .{
            .rule_id = try alloc.dupe(u8, diag.rule_id),
            .severity = sev,
            .file_offset = @intCast(diag.start_offset),
            .byte_length = @intCast(diag.byte_length),
            .end_offset = @intCast(diag.end_offset),
            .region_tag = if (diag.element_id.len > 0) try alloc.dupe(u8, diag.element_id) else null,
            .message = if (diag.message.len > 0) try alloc.dupe(u8, diag.message) else null,
            .is_remediated = false,
            .remediation_action = "UNRESOLVED",
        });
    }
}

fn appendIssueSlice(
    alloc: Allocator,
    list: *std.ArrayList(media_ir.AuditFindingRow),
    issues: anytype,
) !void {
    for (issues) |issue| {
        const region_tag: ?[]const u8 = if (@hasField(@TypeOf(issue), "fourcc")) blk: {
            break :blk if (issue.fourcc) |fcc| try alloc.dupe(u8, &fcc.bytes) else null;
        } else if (@hasField(@TypeOf(issue), "element_id")) blk: {
            break :blk if (issue.element_id) |eid| try std.fmt.allocPrint(alloc, "0x{x}", .{eid}) else null;
        } else null;

        try list.append(alloc, .{
            .rule_id = @tagName(issue.code),
            .severity = 2,
            .file_offset = @intCast(issue.offset),
            .byte_length = 0,
            .end_offset = @intCast(issue.offset),
            .region_tag = region_tag,
            .message = if (issue.details.len > 0) try alloc.dupe(u8, issue.details) else null,
            .is_remediated = false,
            .remediation_action = "UNRESOLVED",
        });
    }
}

fn isPrintableFourCC(tag: [4]u8) bool {
    for (tag) |b| {
        if (!std.ascii.isPrint(b)) return false;
    }
    return true;
}
