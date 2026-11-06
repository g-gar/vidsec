const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("vidsec_formats_common");
const ElementContext = common.ElementContext;
const DiagnosticList = common.DiagnosticList;

/// In-line check verifying that box FourCC consists of printable ASCII characters.
pub fn checkFourccPrintable(
    _: ?*anyopaque,
    elem: ElementContext,
    diagnostics: *DiagnosticList,
    allocator: Allocator,
) anyerror!void {
    var is_printable = true;
    for (elem.id_str) |c| {
        if (!std.ascii.isPrint(c)) {
            is_printable = false;
            break;
        }
    }

    if (!is_printable) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Box at offset {d} contains non-printable FourCC control bytes",
            .{elem.offset},
        );
        try diagnostics.append(allocator, .{
            .rule_id = "isobmff.non_printable_fourcc",
            .severity = .warning,
            .start_offset = elem.offset,
            .end_offset = elem.offset + elem.header_size,
            .byte_length = elem.header_size,
            .element_id = elem.id_str,
            .message = msg,
        });
    }
}
