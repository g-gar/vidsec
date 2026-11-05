const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types/mod.zig");
const define_pure_task = @import("define_pure_task.zig");
const abi_logger = @import("abi_logger.zig");

const TaskDescriptor_ABI = types.TaskDescriptor_ABI;
const TaskResult_ABI = types.TaskResult_ABI;
const MemContext_ABI = types.MemContext_ABI;
const PayloadHandle_ABI = types.PayloadHandle_ABI;
const ExecutionOptions_ABI = types.ExecutionOptions_ABI;
const AbiLogger = abi_logger.AbiLogger;
const computeOutputFields = define_pure_task.computeOutputFields;

/// Compiles a native Zig task into a C-ABI compliant `TaskDescriptor_ABI` with zero-copy Black Box semantics.
/// Automatically handles:
/// - Elemental 1->1 tasks with automatic stream lifting (N -> N)
/// - Expansion 1->N tasks with automatic stream flattening (N -> N*M)
/// - Batch stream tasks ([]const In -> []Out)
/// - Raw binary probe tasks ([]const u8 -> Out or []Out)
/// - Automatic memory bridge via `MemContext_ABI` -> `std.mem.Allocator`
/// - Optional telemetry and logger injection
/// - Compile-time schema reflection for pre-flight pipeline validation
pub fn defineBlackBoxTask(comptime spec: anytype) TaskDescriptor_ABI {
    const RunFnType = switch (@typeInfo(@TypeOf(spec.run))) {
        .pointer => |p| p.child,
        .@"fn" => @TypeOf(spec.run),
        else => @compileError("spec.run must be a function or function pointer"),
    };
    const fn_info = @typeInfo(RunFnType).@"fn";

    const takes_allocator = fn_info.params.len >= 1 and fn_info.params[0].type.? == Allocator;
    const in_param_idx: usize = if (takes_allocator) 1 else 0;
    if (fn_info.params.len <= in_param_idx) {
        @compileError("Task function must take at least an input payload parameter");
    }

    const InType = fn_info.params[in_param_idx].type.?;
    const has_trailing_opt = fn_info.params.len > (in_param_idx + 1);
    const TrailingType = if (has_trailing_opt) fn_info.params[in_param_idx + 1].type.? else void;

    const ReturnType = fn_info.return_type orelse @compileError("Task function must have a return type");
    const ret_info = @typeInfo(ReturnType);
    const PayloadOut = if (ret_info == .error_union) ret_info.error_union.payload else ReturnType;

    const is_in_bytes = InType == []const u8 or InType == []u8;
    const is_in_slice = !is_in_bytes and @typeInfo(InType) == .pointer and @typeInfo(InType).pointer.size == .slice;
    const InElem = if (is_in_slice) @typeInfo(InType).pointer.child else InType;

    const is_out_slice = @typeInfo(PayloadOut) == .pointer and @typeInfo(PayloadOut).pointer.size == .slice;
    const OutElem = if (is_out_slice) @typeInfo(PayloadOut).pointer.child else PayloadOut;

    const has_struct_fields = @typeInfo(OutElem) == .@"struct";
    const output_fields = if (has_struct_fields) computeOutputFields(OutElem) else &.{};

    const Trampoline = struct {
        fn invokeRun(
            alloc: Allocator,
            in_val: anytype,
            options: ExecutionOptions_ABI,
        ) !PayloadOut {
            if (takes_allocator) {
                if (has_trailing_opt) {
                    if (TrailingType == AbiLogger) {
                        return try spec.run(alloc, in_val, AbiLogger{ .log_fn = options.log_fn });
                    } else if (TrailingType == ExecutionOptions_ABI) {
                        return try spec.run(alloc, in_val, options);
                    } else {
                        @compileError("Unsupported 3rd parameter type for task function. Expected AbiLogger or ExecutionOptions_ABI.");
                    }
                } else {
                    return try spec.run(alloc, in_val);
                }
            } else {
                if (has_trailing_opt) {
                    if (TrailingType == AbiLogger) {
                        return try spec.run(in_val, AbiLogger{ .log_fn = options.log_fn });
                    } else if (TrailingType == ExecutionOptions_ABI) {
                        return try spec.run(in_val, options);
                    } else {
                        @compileError("Unsupported 2nd parameter type for task function without allocator.");
                    }
                } else {
                    return try spec.run(in_val);
                }
            }
        }

        fn execute(
            mem: *const MemContext_ABI,
            in_payload: PayloadHandle_ABI,
            options: ExecutionOptions_ABI,
        ) callconv(.c) TaskResult_ABI {
            var alloc = mem.toAllocator();

            // Scenario 1: Function explicitly takes raw bytes
            if (is_in_bytes) {
                const bytes = in_payload.asBytes();
                const out_val = invokeRun(alloc, bytes, options) catch |err| {
                    return TaskResult_ABI.fatal(@errorName(err));
                };
                if (is_out_slice) {
                    return TaskResult_ABI.ok(PayloadHandle_ABI.fromSlice(OutElem, out_val));
                } else {
                    const boxed = alloc.create(OutElem) catch return TaskResult_ABI.fatal("OutOfMemory");
                    boxed.* = out_val;
                    return TaskResult_ABI.ok(PayloadHandle_ABI.fromScalar(OutElem, boxed));
                }
            }

            // Scenario 2: Function explicitly takes a typed slice ([]const InElem)
            if (is_in_slice) {
                const slice = in_payload.asSlice(InElem);
                const out_val = invokeRun(alloc, slice, options) catch |err| {
                    return TaskResult_ABI.fatal(@errorName(err));
                };
                if (is_out_slice) {
                    return TaskResult_ABI.ok(PayloadHandle_ABI.fromSlice(OutElem, out_val));
                } else {
                    const boxed = alloc.create(OutElem) catch return TaskResult_ABI.fatal("OutOfMemory");
                    boxed.* = out_val;
                    return TaskResult_ABI.ok(PayloadHandle_ABI.fromScalar(OutElem, boxed));
                }
            }

            // Scenario 3: Elemental function (InElem scalar)
            if (in_payload.is_stream) {
                const in_items = in_payload.asSlice(InElem);
                if (is_out_slice) {
                    // Expansion: InElem -> []OutElem (flattened)
                    var flattened: std.ArrayListUnmanaged(OutElem) = .empty;
                    errdefer flattened.deinit(alloc);
                    for (in_items) |item| {
                        const sub = invokeRun(alloc, item, options) catch |err| {
                            return TaskResult_ABI.fatal(@errorName(err));
                        };
                        defer alloc.free(sub);
                        flattened.appendSlice(alloc, sub) catch return TaskResult_ABI.fatal("OutOfMemory");
                    }
                    const owned = flattened.toOwnedSlice(alloc) catch return TaskResult_ABI.fatal("OutOfMemory");
                    return TaskResult_ABI.ok(PayloadHandle_ABI.fromSlice(OutElem, owned));
                } else {
                    // Elemental: InElem -> OutElem
                    const out_items = alloc.alloc(OutElem, in_items.len) catch return TaskResult_ABI.fatal("OutOfMemory");
                    for (in_items, 0..) |item, i| {
                        out_items[i] = invokeRun(alloc, item, options) catch |err| {
                            return TaskResult_ABI.fatal(@errorName(err));
                        };
                    }
                    return TaskResult_ABI.ok(PayloadHandle_ABI.fromSlice(OutElem, out_items));
                }
            } else {
                // Scalar execution
                const in_item = in_payload.asScalar(InElem).*;
                const out_val = invokeRun(alloc, in_item, options) catch |err| {
                    return TaskResult_ABI.fatal(@errorName(err));
                };
                if (is_out_slice) {
                    return TaskResult_ABI.ok(PayloadHandle_ABI.fromSlice(OutElem, out_val));
                } else {
                    const boxed = alloc.create(OutElem) catch return TaskResult_ABI.fatal("OutOfMemory");
                    boxed.* = out_val;
                    return TaskResult_ABI.ok(PayloadHandle_ABI.fromScalar(OutElem, boxed));
                }
            }
        }
    };

    const name_z: [:0]const u8 = (spec.name ++ "\x00")[0..spec.name.len :0];
    const desc_z: [:0]const u8 = if (@hasField(@TypeOf(spec), "description"))
        (spec.description ++ "\x00")[0..spec.description.len :0]
    else
        "";

    return .{
        .task_name = name_z.ptr,
        .description = desc_z.ptr,
        .output_fields_ptr = if (output_fields.len > 0) output_fields.ptr else null,
        .output_fields_len = output_fields.len,
        .required_params_ptr = null,
        .required_params_len = 0,
        .execute_blackbox = &Trampoline.execute,
    };
}
