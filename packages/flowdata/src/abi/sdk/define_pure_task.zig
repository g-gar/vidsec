const std = @import("std");
const types = @import("../types/mod.zig");
const TaskContext = @import("task_context.zig").TaskContext;
const PureTaskSpec = @import("pure_task_spec.zig").PureTaskSpec;
const Logger = @import("logger.zig").Logger;
const input_injector = @import("input_injector.zig");

const TaskDescriptor_ABI = types.TaskDescriptor_ABI;
const TaskContext_ABI = types.TaskContext_ABI;
const TaskStatus_ABI = types.TaskStatus_ABI;
const VIDSEC_ABI_VERSION = types.VIDSEC_ABI_VERSION;

/// Computes the list of output field names from `Outputs` at compile time.
pub fn computeOutputFields(comptime Outputs: type) []const [*:0]const u8 {
    const fields = @typeInfo(Outputs).@"struct".fields;
    comptime var names: [fields.len][*:0]const u8 = undefined;
    inline for (fields, 0..) |f, i| {
        const name_z: [:0]const u8 = (f.name ++ "\x00")[0..f.name.len :0];
        names[i] = name_z.ptr;
    }
    const final_names = names;
    return &final_names;
}

/// Wraps a pure business logic task `fn (inputs: Inputs) anyerror!Outputs` (or with `Logger`)
/// into a C-ABI `TaskDescriptor_ABI`.
/// Automatically injects `Inputs` before execution and emits `Outputs` via `ctx.emitTypedRow` after.
pub fn definePureTask(
    comptime Inputs: type,
    comptime Outputs: type,
    comptime spec: anytype,
) TaskDescriptor_ABI {
    const required_params = input_injector.computeRequiredParams(Inputs);
    const output_fields = computeOutputFields(Outputs);
    const description_z: [:0]const u8 = if (@hasField(@TypeOf(spec), "description")) spec.description else "";
    const channel_z: ?[:0]const u8 = if (@hasField(@TypeOf(spec), "output_channel")) spec.output_channel else null;

    const Trampoline = struct {
        pub fn execute(raw_ctx: *TaskContext_ABI) callconv(.c) TaskStatus_ABI {
            const ctx = TaskContext.init(raw_ctx);
            if (raw_ctx.abi_version != VIDSEC_ABI_VERSION) {
                ctx.logError("ABI version mismatch in TaskContext_ABI");
                return .fatal_error;
            }

            const inputs = input_injector.injectInputs(Inputs, ctx) catch |err| {
                ctx.logErrorFmt("Failed to inject inputs for task '{s}': {s}", .{ spec.name, @errorName(err) });
                return .fatal_error;
            };

            const RunFnType = switch (@typeInfo(@TypeOf(spec.run))) {
                .pointer => |p| p.child,
                .@"fn" => @TypeOf(spec.run),
                else => @compileError("spec.run must be a function or function pointer"),
            };
            const num_params = @typeInfo(RunFnType).@"fn".params.len;

            const outputs = if (num_params == 1)
                spec.run(inputs) catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                }
            else if (num_params == 2)
                spec.run(inputs, Logger.init(raw_ctx)) catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                }
            else
                @compileError("pure task run function must take 1 or 2 parameters");

            ctx.emitTypedRow(channel_z, outputs) catch |err| {
                ctx.logErrorFmt("Task '{s}' failed to emit outputs: {s}", .{ spec.name, @errorName(err) });
                return .fatal_error;
            };

            return .ok;
        }
    };

    return .{
        .task_name = spec.name.ptr,
        .description = description_z.ptr,
        .output_fields_ptr = if (output_fields.len > 0) output_fields.ptr else null,
        .output_fields_len = output_fields.len,
        .required_params_ptr = if (required_params.len > 0) required_params.ptr else null,
        .required_params_len = required_params.len,
        .execute = &Trampoline.execute,
    };
}
