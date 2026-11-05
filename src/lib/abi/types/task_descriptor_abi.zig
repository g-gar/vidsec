const std = @import("std");
const TaskExecuteFn_ABI = @import("task_execute_fn_abi.zig").TaskExecuteFn_ABI;
const TaskFn_ABI = @import("task_fn_abi.zig").TaskFn_ABI;
const TaskContext_ABI = @import("task_context_abi.zig").TaskContext_ABI;
const TaskStatus_ABI = @import("task_status_abi.zig").TaskStatus_ABI;

fn defaultExecuteStub(ctx: *TaskContext_ABI) callconv(.c) TaskStatus_ABI {
    _ = ctx;
    return .fatal_error;
}

/// Metadata and entrypoint for a single task exposed by a plugin module.
pub const TaskDescriptor_ABI = extern struct {
    task_name: [*:0]const u8,
    description: [*:0]const u8,
    /// Optional catalog of field names that this task can emit via `emit_row` (validated during pre-flight).
    output_fields_ptr: ?[*]const [*:0]const u8 = null,
    output_fields_len: usize = 0,
    /// Optional catalog of required parameter names in `params:` (validated during pre-flight).
    required_params_ptr: ?[*]const [*:0]const u8 = null,
    required_params_len: usize = 0,
    /// Legacy streaming entrypoint (using TaskContext_ABI / emit_row). Defaults to stub for blackbox tasks.
    execute: TaskExecuteFn_ABI = &defaultExecuteStub,
    /// Modern pure blackbox entrypoint: (MemContext, InPayload, Options) -> TaskResult.
    execute_blackbox: ?TaskFn_ABI = null,

    pub fn nameSlice(self: TaskDescriptor_ABI) []const u8 {
        return std.mem.span(self.task_name);
    }

    pub fn descriptionSlice(self: TaskDescriptor_ABI) []const u8 {
        return std.mem.span(self.description);
    }

    pub fn outputFields(self: TaskDescriptor_ABI) []const [*:0]const u8 {
        const ptr = self.output_fields_ptr orelse return &.{};
        if (self.output_fields_len == 0) return &.{};
        return ptr[0..self.output_fields_len];
    }

    pub fn requiredParams(self: TaskDescriptor_ABI) []const [*:0]const u8 {
        const ptr = self.required_params_ptr orelse return &.{};
        if (self.required_params_len == 0) return &.{};
        return ptr[0..self.required_params_len];
    }

    /// Returns `true` if `field_name` is in `output_fields`, or if the task does not constrain `output_fields`.
    pub fn declaresOutputField(self: TaskDescriptor_ABI, field_name: []const u8) bool {
        const fields = self.outputFields();
        if (fields.len == 0) return true;
        for (fields) |f_ptr| {
            if (std.mem.eql(u8, std.mem.span(f_ptr), field_name)) return true;
        }
        return false;
    }
};
