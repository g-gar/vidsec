const std = @import("std");
const Allocator = std.mem.Allocator;
const ElementContext = @import("../entities/element_context.zig").ElementContext;
const DiagnosticList = @import("../entities/diagnostic_list.zig").DiagnosticList;

/// Abstract function pointer signature for in-line element checks executed during parsing.
pub const InLineCheckFn = *const fn (
    ctx: ?*anyopaque,
    element: ElementContext,
    diagnostics: *DiagnosticList,
    allocator: Allocator,
) anyerror!void;

/// Invocation wrapper pairing a check function with its optional instance context.
pub const InLineCheck = struct {
    ctx: ?*anyopaque = null,
    run_fn: InLineCheckFn,

    pub fn execute(
        self: InLineCheck,
        element: ElementContext,
        diagnostics: *DiagnosticList,
        allocator: Allocator,
    ) !void {
        try self.run_fn(self.ctx, element, diagnostics, allocator);
    }
};
