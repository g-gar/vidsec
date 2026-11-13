const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types/mod.zig");
const TaskContext = @import("task_context.zig").TaskContext;
const input_injector = @import("input_injector.zig");
const define_pure_task = @import("define_pure_task.zig");
const computeOutputFields = define_pure_task.computeOutputFields;
const logger_mod = @import("logger.zig");

const TaskDescriptor_ABI = types.TaskDescriptor_ABI;
const FieldMeta_ABI = types.FieldMeta_ABI;
const TaskContext_ABI = types.TaskContext_ABI;
const TaskStatus_ABI = types.TaskStatus_ABI;
const FLOWDATA_ABI_VERSION = types.FLOWDATA_ABI_VERSION;

/// Deduces the `Inputs` struct type from `RunFnType` via compile-time reflection.
/// If no struct input parameter exists, returns `void`.
fn deduceInputsType(comptime RunFnType: type) type {
    const fn_info = @typeInfo(RunFnType).@"fn";
    inline for (fn_info.params) |param| {
        const P = param.type orelse continue;
        if (P != Allocator and P != TaskContext and P != logger_mod.Logger) {
            return P;
        }
    }
    return void;
}

/// Maps a Zig field type to its Flowdata logical column type name (ARCH-009A §2.2).
pub fn zigTypeToLogical(comptime T: type) [*:0]const u8 {
    return switch (@typeInfo(T)) {
        .optional => |opt| zigTypeToLogical(opt.child),
        .int => |i| if (i.signedness == .signed) "int64" else "uint64",
        .comptime_int => "int64",
        .float, .comptime_float => "float64",
        .bool => "bool",
        .@"enum" => "enum_type",
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) break :blk "text";
            break :blk "json";
        },
        .@"struct" => "json",
        else => "text",
    };
}

/// Generates compile-time `FieldMeta_ABI` slice for any struct type `T`.
pub fn computeFieldMeta(comptime T: type) []const FieldMeta_ABI {
    const info = @typeInfo(T);
    if (info != .@"struct") return &.{};
    const fields = info.@"struct".fields;
    if (fields.len == 0) return &.{};
    comptime var arr: [fields.len]FieldMeta_ABI = undefined;
    inline for (fields, 0..) |f, i| {
        const is_opt = @typeInfo(f.type) == .optional;
        arr[i] = .{
            .name = (f.name ++ "\x00")[0..f.name.len :0].ptr,
            .logical_type = comptime zigTypeToLogical(f.type),
            .nullable = is_opt,
        };
    }
    const final_arr = arr;
    return &final_arr;
}

/// Coerces a tuple or slice of string literals into `[]const [*:0]const u8`.
fn coerceStringList(comptime raw_list: anytype) []const [*:0]const u8 {
    const RawType = @TypeOf(raw_list);
    const info = @typeInfo(RawType);
    if (info == .pointer and @typeInfo(info.pointer.child) == .@"struct") {
        const fields = @typeInfo(info.pointer.child).@"struct".fields;
        comptime var arr: [fields.len][*:0]const u8 = undefined;
        inline for (fields, 0..) |f, i| {
            const val = @field(raw_list.*, f.name);
            arr[i] = val.ptr;
        }
        const final_arr = arr;
        return &final_arr;
    } else if (info == .pointer and info.pointer.size == .slice) {
        return raw_list;
    } else {
        return &.{};
    }
}

/// Wraps a declarative task specification at compile time into a C-ABI `TaskDescriptor_ABI`.
/// Automatically deduces `Inputs` and `Outputs` types from `spec.run` signature via reflection.
/// Automatically injects `inputs: Inputs` from host context (`params:` and `inputs:`).
/// Supports returning:
/// - `TaskStatus_ABI`
/// - A typed struct (`Outputs`)
/// - A slice of structs (`[]Outputs`)
/// - A primitive scalar (`i64`, `f64`, `bool`, `[]const u8`)
///
/// Supported task function signatures:
/// - `fn (alloc: Allocator, ctx: TaskContext, inputs: Inputs) !Outputs`
/// - `fn (alloc: Allocator, inputs: Inputs) !Outputs`
/// - `fn (ctx: TaskContext, inputs: Inputs) !Outputs`
/// - `fn (inputs: Inputs) !Outputs`
/// - `fn (alloc: Allocator, ctx: TaskContext) !Outputs`
/// - `fn (ctx: TaskContext) !Outputs`
/// - `fn (alloc: Allocator) !Outputs`
/// - `fn () !Outputs`
pub fn defineTask(comptime spec: anytype) TaskDescriptor_ABI {
    const RunFnType = switch (@typeInfo(@TypeOf(spec.run))) {
        .pointer => |p| p.child,
        .@"fn" => @TypeOf(spec.run),
        else => @compileError("spec.run must be a function or function pointer"),
    };
    const fn_info = @typeInfo(RunFnType).@"fn";
    const Inputs = deduceInputsType(RunFnType);
    const has_inputs = (Inputs != void);

    const required_params = if (has_inputs)
        input_injector.computeRequiredParams(Inputs)
    else if (@hasField(@TypeOf(spec), "required_params"))
        coerceStringList(spec.required_params)
    else
        &.{};

    const ReturnType = fn_info.return_type orelse @compileError("spec.run must have a return type");
    const ret_info = @typeInfo(ReturnType);
    const PayloadOut = if (ret_info == .error_union) ret_info.error_union.payload else ReturnType;

    const is_slice = @typeInfo(PayloadOut) == .pointer and @typeInfo(PayloadOut).pointer.size == .slice and PayloadOut != []const u8 and PayloadOut != []u8;
    const ElemType = if (is_slice) @typeInfo(PayloadOut).pointer.child else PayloadOut;

    const description_z: [:0]const u8 = if (@hasField(@TypeOf(spec), "description")) spec.description else "";

    const computed_output_fields = if (@hasField(@TypeOf(spec), "output_fields"))
        coerceStringList(spec.output_fields)
    else if (ElemType != TaskStatus_ABI and ElemType != void)
        computeOutputFields(ElemType)
    else
        &.{};

    const computed_input_meta: []const FieldMeta_ABI = if (has_inputs) computeFieldMeta(Inputs) else &.{};
    const computed_output_meta: []const FieldMeta_ABI = if (ElemType != TaskStatus_ABI and ElemType != void) computeFieldMeta(ElemType) else &.{};

    // Parameter layout detection
    const takes_allocator = fn_info.params.len >= 1 and fn_info.params[0].type.? == Allocator;
    const ctx_param_idx: usize = if (takes_allocator) 1 else 0;
    const takes_ctx = fn_info.params.len > ctx_param_idx and fn_info.params[ctx_param_idx].type.? == TaskContext;

    const Trampoline = struct {
        pub fn execute(raw_ctx: *TaskContext_ABI) callconv(.c) TaskStatus_ABI {
            const ctx = TaskContext.init(raw_ctx);
            if (raw_ctx.abi_version != FLOWDATA_ABI_VERSION) {
                ctx.logError("ABI version mismatch in TaskContext_ABI");
                return .fatal_error;
            }

            var step_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer step_arena.deinit();
            const alloc = step_arena.allocator();

            const inputs = if (has_inputs)
                input_injector.injectInputs(Inputs, ctx) catch |err| {
                    ctx.logErrorFmt("Failed to inject inputs for task '{s}': {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                }
            else
                .{};

            const result = if (takes_allocator and takes_ctx and has_inputs)
                spec.run(alloc, ctx, inputs) catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                }
            else if (takes_allocator and takes_ctx and !has_inputs)
                spec.run(alloc, ctx) catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                }
            else if (takes_allocator and !takes_ctx and has_inputs)
                spec.run(alloc, inputs) catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                }
            else if (takes_allocator and !takes_ctx and !has_inputs)
                spec.run(alloc) catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                }
            else if (!takes_allocator and takes_ctx and has_inputs)
                spec.run(ctx, inputs) catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                }
            else if (!takes_allocator and takes_ctx and !has_inputs)
                spec.run(ctx) catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                }
            else if (!takes_allocator and !takes_ctx and has_inputs)
                spec.run(inputs) catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                }
            else
                spec.run() catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                };

            if (PayloadOut == TaskStatus_ABI) {
                return result;
            } else if (PayloadOut == void) {
                return .ok;
            } else if (is_slice) {
                for (result) |item| {
                    ctx.emitTypedRow(item) catch |err| {
                        ctx.logErrorFmt("Task '{s}' failed to emit output row: {s}", .{ spec.name, @errorName(err) });
                        return .fatal_error;
                    };
                }
                return .ok;
            } else {
                ctx.emitTypedRow(result) catch |err| {
                    ctx.logErrorFmt("Task '{s}' failed to emit output: {s}", .{ spec.name, @errorName(err) });
                    return .fatal_error;
                };
                return .ok;
            }
        }
    };

    return .{
        .task_name = spec.name.ptr,
        .description = description_z.ptr,
        .output_fields_ptr = if (computed_output_fields.len > 0) computed_output_fields.ptr else null,
        .output_fields_len = computed_output_fields.len,
        .required_params_ptr = if (required_params.len > 0) required_params.ptr else null,
        .required_params_len = required_params.len,
        .execute = &Trampoline.execute,
        .input_meta_ptr = if (computed_input_meta.len > 0) computed_input_meta.ptr else null,
        .input_meta_len = computed_input_meta.len,
        .output_meta_ptr = if (computed_output_meta.len > 0) computed_output_meta.ptr else null,
        .output_meta_len = computed_output_meta.len,
    };
}
