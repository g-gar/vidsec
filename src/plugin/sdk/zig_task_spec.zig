const types = @import("../types/mod.zig");
const TaskContext = @import("task_context.zig").TaskContext;

/// Declarative specification used with `defineTask` to wrap an idiomatic Zig function
/// `fn (ctx: TaskContext) anyerror!TaskStatus_ABI` into a `callconv(.c)` `TaskDescriptor_ABI`.
pub const ZigTaskSpec = struct {
    name: [:0]const u8,
    description: [:0]const u8 = "",
    output_fields: []const [*:0]const u8 = &.{},
    required_params: []const [*:0]const u8 = &.{},
    run: *const fn (ctx: TaskContext) anyerror!types.TaskStatus_ABI,
};
