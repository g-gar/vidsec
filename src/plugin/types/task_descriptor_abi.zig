const std = @import("std");
const TaskExecuteFn_ABI = @import("task_execute_fn_abi.zig").TaskExecuteFn_ABI;
const TaskFn_ABI = @import("task_fn_abi.zig").TaskFn_ABI;
const TaskContext_ABI = @import("task_context_abi.zig").TaskContext_ABI;
const TaskStatus_ABI = @import("task_status_abi.zig").TaskStatus_ABI;
const PayloadHandle_ABI = @import("payload_handle_abi.zig").PayloadHandle_ABI;

/// Predicate function signature for service catalog matching (ARCH-018 §3.1).
pub const CanHandleFn_ABI = *const fn (payload: *const PayloadHandle_ABI) callconv(.c) bool;

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
    // ARCH-016 flags: bit 0: lift_elemental, bit 1: concurrency_safe, bit 2: passthrough
    flags: u32 = 0,
    /// ARCH-018: Affinity predicate for dynamic schema matching & service catalog.
    can_handle: ?CanHandleFn_ABI = null,

    pub const FLAG_LIFT_ELEMENTAL: u32 = 1 << 0;
    pub const FLAG_CONCURRENCY_SAFE: u32 = 1 << 1;
    pub const FLAG_PASSTHROUGH: u32 = 1 << 2;

    pub fn canHandle(self: TaskDescriptor_ABI, payload: *const PayloadHandle_ABI) bool {
        if (self.can_handle) |ch| {
            return ch(payload);
        }
        return true;
    }

    pub fn isLiftElemental(self: TaskDescriptor_ABI) bool {
        return (self.flags & FLAG_LIFT_ELEMENTAL) != 0;
    }

    pub fn isConcurrencySafe(self: TaskDescriptor_ABI) bool {
        return (self.flags & FLAG_CONCURRENCY_SAFE) != 0;
    }

    pub fn isPassthrough(self: TaskDescriptor_ABI) bool {
        return (self.flags & FLAG_PASSTHROUGH) != 0;
    }

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
