const types = @import("../types/mod.zig");
const TaskContext = @import("task_context.zig").TaskContext;
const ZigTaskSpec = @import("zig_task_spec.zig").ZigTaskSpec;

const TaskDescriptor_ABI = types.TaskDescriptor_ABI;
const TaskContext_ABI = types.TaskContext_ABI;
const TaskStatus_ABI = types.TaskStatus_ABI;
const FLOWDATA_ABI_VERSION = types.FLOWDATA_ABI_VERSION;

/// Wraps a `ZigTaskSpec` at compile time into a C-ABI `TaskDescriptor_ABI`, automatically
/// logging any unhandled Zig error via `ctx.logError(@errorName(err))` and returning `.fatal_error`.
pub fn defineTask(comptime spec: ZigTaskSpec) TaskDescriptor_ABI {
    const Trampoline = struct {
        pub fn execute(raw_ctx: *TaskContext_ABI) callconv(.c) TaskStatus_ABI {
            const ctx = TaskContext.init(raw_ctx);
            if (raw_ctx.abi_version != FLOWDATA_ABI_VERSION) {
                ctx.logError("ABI version mismatch in TaskContext_ABI");
                return .fatal_error;
            }
            return spec.run(ctx) catch |err| {
                ctx.logError(@errorName(err));
                return .fatal_error;
            };
        }
    };

    return .{
        .task_name = spec.name.ptr,
        .description = spec.description.ptr,
        .output_fields_ptr = if (spec.output_fields.len > 0) spec.output_fields.ptr else null,
        .output_fields_len = spec.output_fields.len,
        .required_params_ptr = if (spec.required_params.len > 0) spec.required_params.ptr else null,
        .required_params_len = spec.required_params.len,
        .execute = &Trampoline.execute,
    };
}
