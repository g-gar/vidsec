const types = @import("../types/mod.zig");
const TaskContext = @import("task_context.zig").TaskContext;

/// Specification for a task that receives a strongly-typed, auto-injected `Inputs` struct.
pub fn BoundTaskSpec(comptime Inputs: type) type {
    return struct {
        name: [:0]const u8,
        description: [:0]const u8 = "",
        output_fields: []const [*:0]const u8 = &.{},
        run: *const fn (ctx: TaskContext, inputs: Inputs) anyerror!types.TaskStatus_ABI,
    };
}
