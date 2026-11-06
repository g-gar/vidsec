const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("vidsec_formats_common");
const ElementContext = common.ElementContext;
const DiagnosticList = common.DiagnosticList;

/// In-line check verifying that RIFF chunk size does not overflow u64 or exceed file bounds.
pub fn checkChunkOverflow(
    _: ?*anyopaque,
    elem: ElementContext,
    diagnostics: *DiagnosticList,
    allocator: Allocator,
) anyerror!void {
    const end, const overflow = @addWithOverflow(elem.offset, elem.declared_size);
    if (overflow != 0) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "RIFF chunk '{s}' size {d} causes 64-bit integer overflow at offset {d}",
            .{ elem.id_str, elem.declared_size, elem.offset },
        );
        try diagnostics.append(allocator, .{
            .rule_id = "riff.chunk_size_overflow",
            .severity = .critical,
            .start_offset = elem.offset,
            .end_offset = elem.file_size,
            .byte_length = elem.declared_size,
            .element_id = elem.id_str,
            .message = msg,
        });
        return;
    }

    if (end > elem.file_size) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "RIFF chunk '{s}' size {d} extends beyond file bounds ({d} > {d})",
            .{ elem.id_str, elem.declared_size, end, elem.file_size },
        );
        try diagnostics.append(allocator, .{
            .rule_id = "riff.chunk_size_overflow",
            .severity = .critical,
            .start_offset = elem.offset,
            .end_offset = end,
            .byte_length = elem.declared_size,
            .element_id = elem.id_str,
            .message = msg,
        });
    }
}
