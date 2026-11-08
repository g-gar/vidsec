const std = @import("std");
const types = @import("../types/mod.zig");
const TaskContext = @import("task_context.zig").TaskContext;
const BoundTaskSpec = @import("bound_task_spec.zig").BoundTaskSpec;
const input_injector = @import("input_injector.zig");

const TaskDescriptor_ABI = types.TaskDescriptor_ABI;
const TaskContext_ABI = types.TaskContext_ABI;
const TaskStatus_ABI = types.TaskStatus_ABI;
const FLOWDATA_ABI_VERSION = types.FLOWDATA_ABI_VERSION;

/// Wraps a `BoundTaskSpec(Inputs)` at compile time into a C-ABI `TaskDescriptor_ABI`,
/// automatically injecting `inputs: Inputs` from the host context (`params:` and `inputs:`)
/// before calling the task implementation.
pub fn defineBoundTask(comptime Inputs: type, comptime spec: BoundTaskSpec(Inputs)) TaskDescriptor_ABI {
    const required_params = input_injector.computeRequiredParams(Inputs);

    const Trampoline = struct {
        pub fn execute(raw_ctx: *TaskContext_ABI) callconv(.c) TaskStatus_ABI {
            const ctx = TaskContext.init(raw_ctx);
            if (raw_ctx.abi_version != FLOWDATA_ABI_VERSION) {
                ctx.logError("ABI version mismatch in TaskContext_ABI");
                return .fatal_error;
            }
            const inputs = input_injector.injectInputs(Inputs, ctx) catch |err| {
                ctx.logErrorFmt("Failed to inject inputs for task '{s}': {s}", .{ spec.name, @errorName(err) });
                return .fatal_error;
            };
            return spec.run(ctx, inputs) catch |err| {
                ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                return .fatal_error;
            };
        }
    };

    return .{
        .task_name = spec.name.ptr,
        .description = spec.description.ptr,
        .output_fields_ptr = if (spec.output_fields.len > 0) spec.output_fields.ptr else null,
        .output_fields_len = spec.output_fields.len,
        .required_params_ptr = if (required_params.len > 0) required_params.ptr else null,
        .required_params_len = required_params.len,
        .execute = &Trampoline.execute,
    };
}
