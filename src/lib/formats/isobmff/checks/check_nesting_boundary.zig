const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("vidsec_formats_common");
const ElementContext = common.ElementContext;
const DiagnosticList = common.DiagnosticList;

/// In-line check verifying that child box does not exceed parent container boundaries.
pub fn checkNestingBoundary(
    _: ?*anyopaque,
    elem: ElementContext,
    diagnostics: *DiagnosticList,
    allocator: Allocator,
) anyerror!void {
    if (elem.depth > 32) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Box '{s}' nesting depth {d} exceeds maximum parser recursion limit (32)",
            .{ elem.id_str, elem.depth },
        );
        try diagnostics.append(allocator, .{
            .rule_id = "isobmff.recursion_depth_exceeded",
            .severity = .critical,
            .start_offset = elem.offset,
            .end_offset = elem.offset + elem.declared_size,
            .byte_length = elem.declared_size,
            .element_id = elem.id_str,
            .message = msg,
        });
    }
}
