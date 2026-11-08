const TaskContext_ABI = @import("task_context_abi.zig").TaskContext_ABI;
const TaskStatus_ABI = @import("task_status_abi.zig").TaskStatus_ABI;

/// Entrypoint function signature for a task implementation inside a plugin.
pub const TaskExecuteFn_ABI = *const fn (ctx: *TaskContext_ABI) callconv(.c) TaskStatus_ABI;
