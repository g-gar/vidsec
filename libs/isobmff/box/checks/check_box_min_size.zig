const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("media_ir").common;
const ElementContext = common.ElementContext;
const DiagnosticList = common.DiagnosticList;

/// In-line check verifying that declared box size is at least the header minimum.
pub fn checkBoxMinSize(
    _: ?*anyopaque,
    elem: ElementContext,
    diagnostics: *DiagnosticList,
    allocator: Allocator,
) anyerror!void {
    if (elem.declared_size < elem.header_size and elem.declared_size != 0) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Box '{s}' declared size {d} is smaller than minimum header size ({d})",
            .{ elem.id_str, elem.declared_size, elem.header_size },
        );
        try diagnostics.append(allocator, .{
            .rule_id = "isobmff.box_size_invalid",
            .severity = .critical,
            .start_offset = elem.offset,
            .end_offset = elem.offset + elem.header_size,
            .byte_length = elem.declared_size,
            .element_id = elem.id_str,
            .message = msg,
        });
    }
}
