const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types/mod.zig");
const TaskContext = @import("task_context.zig").TaskContext;
const input_injector = @import("input_injector.zig");
const define_pure_task = @import("define_pure_task.zig");
const di = @import("di.zig");

const TaskDescriptor_ABI = types.TaskDescriptor_ABI;
const TaskContext_ABI = types.TaskContext_ABI;
const TaskStatus_ABI = types.TaskStatus_ABI;
const FLOWDATA_ABI_VERSION = types.FLOWDATA_ABI_VERSION;
const computeOutputFields = define_pure_task.computeOutputFields;

/// Default stateless context for tasks requiring only built-in SDK primitives.
pub const EmptyContext = struct {};

fn deduceServiceInputsType(comptime Service: type, comptime ExecFnType: type) type {
    const fn_info = @typeInfo(ExecFnType).@"fn";
    if (fn_info.params.len == 0) {
        @compileError(@typeName(Service) ++ ".execute must take self as its first parameter");
    }
    inline for (fn_info.params[1..]) |param| {
        const P = param.type orelse continue;
        if (P != Allocator) {
            return P;
        }
    }
    return void;
}

/// Generic DI Container base type. Validates `ContextImpl` at compile time and provides
/// `defineTaskService`, `inject`, and `runWithContext`.
pub fn DiContainer(comptime ContextImpl: type) type {
    comptime di.assertValidContext(ContextImpl);

    return struct {
        pub const ContextType = ContextImpl;

        pub fn initContext(ctx_impl: *ContextImpl, alloc: Allocator, ctx: TaskContext) !void {
            if (@hasDecl(ContextImpl, "init")) {
                try ctx_impl.init(alloc, ctx);
            } else {
                ctx_impl.* = .{};
            }
        }

        pub fn deinitContext(ctx_impl: *ContextImpl) void {
            if (@hasDecl(ContextImpl, "deinit")) {
                ctx_impl.deinit();
            }
        }

        /// Instantiates `Service` from an already-initialized `ContextImpl` (ideal for TestContainer suites).
        pub fn inject(
            comptime Service: type,
            ctx_impl: *ContextImpl,
            alloc: Allocator,
            input: anytype,
        ) !Service {
            return di.injectService(Service, ContextImpl, ctx_impl, alloc, null, input);
        }

        /// Executes `Service` directly against a `TaskContext` and typed `input` (for integration tests).
        pub fn runWithContext(
            comptime Service: type,
            alloc: Allocator,
            ctx: TaskContext,
            input: anytype,
        ) !@typeInfo(@typeInfo(@TypeOf(Service.execute)).@"fn".return_type.?).error_union.payload {
            comptime di.assertValidService(ContextImpl, Service);
            var ctx_impl: ContextImpl = undefined;
            try initContext(&ctx_impl, alloc, ctx);
            defer deinitContext(&ctx_impl);

            var service = try di.injectService(Service, ContextImpl, &ctx_impl, alloc, ctx, input);
            const fn_info = @typeInfo(@TypeOf(Service.execute)).@"fn";
            const takes_alloc = fn_info.params.len >= 2 and fn_info.params[1].type.? == Allocator;
            return if (takes_alloc) try service.execute(alloc, input) else try service.execute(input);
        }

        /// Compiles a declarative `Service` into a C-ABI `TaskDescriptor_ABI`.
        pub fn defineTaskService(comptime Service: type, comptime spec: anytype) TaskDescriptor_ABI {
            comptime di.assertValidService(ContextImpl, Service);

            const ExecFnType = @TypeOf(Service.execute);
            const fn_info = @typeInfo(ExecFnType).@"fn";

            const Inputs = deduceServiceInputsType(Service, ExecFnType);
            const has_inputs = (Inputs != void);
            const takes_allocator = fn_info.params.len >= 2 and fn_info.params[1].type.? == Allocator;

            const required_params = if (has_inputs)
                input_injector.computeRequiredParams(Inputs)
            else
                &.{};

            const ReturnType = fn_info.return_type orelse @compileError("Service.execute must have a return type");
            const ret_info = @typeInfo(ReturnType);
            const PayloadOut = if (ret_info == .error_union) ret_info.error_union.payload else ReturnType;

            const is_slice = @typeInfo(PayloadOut) == .pointer and
                @typeInfo(PayloadOut).pointer.size == .slice and
                PayloadOut != []const u8 and PayloadOut != []u8;
            const ElemType = if (is_slice) @typeInfo(PayloadOut).pointer.child else PayloadOut;

            const description_z: [:0]const u8 = if (@hasField(@TypeOf(spec), "description")) spec.description else "";
            const computed_output_fields = if (ElemType != TaskStatus_ABI and ElemType != void)
                computeOutputFields(ElemType)
            else
                &.{};

            const SelfContainer = @This();

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

                    // 1. Automatically deserialize Input DTO from host context
                    const inputs = if (has_inputs)
                        input_injector.injectInputs(Inputs, ctx) catch |err| {
                            ctx.logErrorFmt("Failed to inject inputs for task '{s}': {s}", .{ spec.name, @errorName(err) });
                            return .fatal_error;
                        }
                    else
                        .{};

                    // 2. Initialize ContextImpl in-place (preserving pointer stability)
                    var ctx_impl: ContextImpl = undefined;
                    SelfContainer.initContext(&ctx_impl, alloc, ctx) catch |err| {
                        ctx.logErrorFmt("Failed to initialize DI context for task '{s}': {s}", .{ spec.name, @errorName(err) });
                        return .fatal_error;
                    };
                    defer SelfContainer.deinitContext(&ctx_impl);

                    // 3. Auto-inject dependencies into Service
                    var service = di.injectService(Service, ContextImpl, &ctx_impl, alloc, ctx, inputs) catch |err| {
                        ctx.logErrorFmt("Failed to resolve dependencies for task '{s}': {s}", .{ spec.name, @errorName(err) });
                        return .fatal_error;
                    };

                    // 4. Invoke pure domain Service.execute
                    const result = if (takes_allocator and has_inputs)
                        service.execute(alloc, inputs) catch |err| {
                            ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                            return .fatal_error;
                        }
                    else if (takes_allocator and !has_inputs)
                        service.execute(alloc) catch |err| {
                            ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                            return .fatal_error;
                        }
                    else if (!takes_allocator and has_inputs)
                        service.execute(inputs) catch |err| {
                            ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                            return .fatal_error;
                        }
                    else
                        service.execute() catch |err| {
                            ctx.logErrorFmt("Task '{s}' failed: {s}", .{ spec.name, @errorName(err) });
                            return .fatal_error;
                        };

                    // 5. Auto-emit typed output (single struct or slice of structs)
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
            };
        }
    };
}

/// Default DI Container for simple tasks requiring only built-in SDK dependencies.
pub const DefaultDiContainer = DiContainer(EmptyContext);
pub const defineTaskService = DefaultDiContainer.defineTaskService;
