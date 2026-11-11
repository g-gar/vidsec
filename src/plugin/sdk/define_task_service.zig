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

            const is_elemental = @hasField(@TypeOf(spec), "lift") and spec.lift == .elemental;
            const is_optional = @typeInfo(PayloadOut) == .optional;
            const is_slice = @typeInfo(PayloadOut) == .pointer and
                @typeInfo(PayloadOut).pointer.size == .slice and
                PayloadOut != []const u8 and PayloadOut != []u8;

            const ElemType = if (is_optional)
                @typeInfo(PayloadOut).optional.child
            else if (is_slice)
                @typeInfo(PayloadOut).pointer.child
            else
                PayloadOut;

            if (is_elemental and !has_inputs) {
                @compileError(".lift = .elemental requires an input parameter for " ++ @typeName(Service) ++ ".execute");
            }

            const is_composite_elemental = comptime blk: {
                if (!is_elemental or @typeInfo(Inputs) != .@"struct") break :blk false;
                for (@typeInfo(Inputs).@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, "item") or std.mem.eql(u8, f.name, "req") or std.mem.eql(u8, f.name, "elem")) {
                        break :blk true;
                    }
                }
                break :blk false;
            };

            const elemental_field_name: []const u8 = comptime blk: {
                if (!is_composite_elemental) break :blk "";
                for (@typeInfo(Inputs).@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, "item") or std.mem.eql(u8, f.name, "req") or std.mem.eql(u8, f.name, "elem")) {
                        break :blk f.name;
                    }
                }
                break :blk "";
            };

            const ItemType = comptime blk: {
                if (!is_elemental) break :blk Inputs;
                if (!is_composite_elemental) break :blk Inputs;
                for (@typeInfo(Inputs).@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, elemental_field_name)) {
                        break :blk f.type;
                    }
                }
                break :blk Inputs;
            };

            if (is_elemental and has_inputs) {
                if (is_composite_elemental) {
                    inline for (@typeInfo(Inputs).@"struct".fields) |f| {
                        if (!std.mem.eql(u8, f.name, elemental_field_name)) {
                            if (@typeInfo(f.type) == .pointer and @typeInfo(f.type).pointer.size == .slice and @typeInfo(f.type).pointer.child != u8) {
                                @compileError(".lift = .elemental broadcast field '" ++ f.name ++ "' cannot be a slice");
                            }
                        }
                    }
                } else {
                    if (@typeInfo(Inputs) == .pointer and @typeInfo(Inputs).pointer.size == .slice and @typeInfo(Inputs).pointer.child != u8) {
                        @compileError(".lift = .elemental input type cannot be a slice; use elemental item type instead");
                    }
                }
            }

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
                    // Prefer host output allocator for returned task outputs; use step_arena for DI/transient work
                    const alloc = ctx.outputAllocator();

                    if (is_elemental) {
                        // 1. Initialize ContextImpl in-place
                        var ctx_impl: ContextImpl = undefined;
                        SelfContainer.initContext(&ctx_impl, alloc, ctx) catch |err| {
                            ctx.logErrorFmt("Failed to initialize DI context for task '{s}': {s}", .{ spec.name, @errorName(err) });
                            return .fatal_error;
                        };
                        defer SelfContainer.deinitContext(&ctx_impl);

                        // 2. Resolve broadcast inputs if composite
                        var broadcast_inputs: Inputs = undefined;
                        if (is_composite_elemental) {
                            inline for (@typeInfo(Inputs).@"struct".fields) |f| {
                                if (!std.mem.eql(u8, f.name, elemental_field_name)) {
                                    const f_key_z: [:0]const u8 = (f.name ++ "\x00")[0..f.name.len :0];
                                    @field(broadcast_inputs, f.name) = input_injector.resolveField(f, ctx, f_key_z) catch |err| {
                                        ctx.logErrorFmt("Failed to inject broadcast field '{s}': {s}", .{ f.name, @errorName(err) });
                                        return .fatal_error;
                                    };
                                }
                            }
                        }

                        // 3. Auto-inject dependencies into Service
                        var service = di.injectService(Service, ContextImpl, &ctx_impl, alloc, ctx, if (is_composite_elemental) broadcast_inputs else .{}) catch |err| {
                            ctx.logErrorFmt("Failed to resolve dependencies for task '{s}': {s}", .{ spec.name, @errorName(err) });
                            return .fatal_error;
                        };

                        // 4. Fetch primary input stream
                        const maybe_primary = (ctx.inputPayload("primary") catch null) orelse
                            (ctx.inputPayload("stream") catch null) orelse
                            (ctx.inputPayload("input") catch null) orelse
                            (ctx.inputPayload("") catch null);

                        const primary_payload = maybe_primary orelse {
                            ctx.emitTypedSlice(null, ElemType, &.{}) catch {};
                            return .ok;
                        };

                        if (primary_payload.len == 0) {
                            ctx.emitTypedSlice(null, ElemType, &.{}) catch {};
                            return .ok;
                        }

                        const in_items = primary_payload.asSlice(ItemType);

                        // 5. Error policy
                        const err_policy = ctx.getParamText("on_item_error", "fail_fast") catch "fail_fast";
                        const is_skip = std.mem.eql(u8, err_policy, "skip");
                        const is_collect = std.mem.eql(u8, err_policy, "collect");

                        // 6. Execute loop by cardinality
                        if (is_optional) {
                            // Filter: 1 -> 0..1
                            var out_list: std.ArrayListUnmanaged(ElemType) = .empty;
                            for (in_items, 0..) |item, i| {
                                if (ctx.isCancelled()) return .halt_pipeline;
                                const input_arg = if (is_composite_elemental) blk: {
                                    var comp = broadcast_inputs;
                                    @field(comp, elemental_field_name) = item;
                                    break :blk comp;
                                } else item;

                                const res = if (takes_allocator)
                                    service.execute(alloc, input_arg)
                                else
                                    service.execute(input_arg);

                                if (res) |maybe_item| {
                                    if (maybe_item) |val| {
                                        out_list.append(alloc, val) catch return .fatal_error;
                                    }
                                } else |err| {
                                    if (is_skip or is_collect) {
                                        ctx.logWarnFmt("Task '{s}' item {d} skipped on error: {s}", .{ spec.name, i, @errorName(err) });
                                        continue;
                                    }
                                    ctx.logErrorFmt("Task '{s}' item {d} failed: {s}", .{ spec.name, i, @errorName(err) });
                                    return .fatal_error;
                                }
                            }
                            ctx.emitTypedSlice(null, ElemType, out_list.items) catch |err| {
                                ctx.logErrorFmt("Task '{s}' failed to emit filtered slice: {s}", .{ spec.name, @errorName(err) });
                                return .fatal_error;
                            };
                            return .ok;
                        } else if (is_slice) {
                            // Expansion: 1 -> M
                            var out_list: std.ArrayListUnmanaged(ElemType) = .empty;
                            for (in_items, 0..) |item, i| {
                                if (ctx.isCancelled()) return .halt_pipeline;
                                const input_arg = if (is_composite_elemental) blk: {
                                    var comp = broadcast_inputs;
                                    @field(comp, elemental_field_name) = item;
                                    break :blk comp;
                                } else item;

                                const res = if (takes_allocator)
                                    service.execute(alloc, input_arg)
                                else
                                    service.execute(input_arg);

                                if (res) |slice_items| {
                                    out_list.appendSlice(alloc, slice_items) catch return .fatal_error;
                                } else |err| {
                                    if (is_skip or is_collect) {
                                        ctx.logWarnFmt("Task '{s}' item {d} skipped on error: {s}", .{ spec.name, i, @errorName(err) });
                                        continue;
                                    }
                                    ctx.logErrorFmt("Task '{s}' item {d} failed: {s}", .{ spec.name, i, @errorName(err) });
                                    return .fatal_error;
                                }
                            }
                            ctx.emitTypedSlice(null, ElemType, out_list.items) catch |err| {
                                ctx.logErrorFmt("Task '{s}' failed to emit expanded slice: {s}", .{ spec.name, @errorName(err) });
                                return .fatal_error;
                            };
                            return .ok;
                        } else {
                            // Map: 1 -> 1
                            var out_slice = alloc.alloc(ElemType, in_items.len) catch return .fatal_error;
                            var written: usize = 0;
                            for (in_items, 0..) |item, i| {
                                if (ctx.isCancelled()) return .halt_pipeline;
                                const input_arg = if (is_composite_elemental) blk: {
                                    var comp = broadcast_inputs;
                                    @field(comp, elemental_field_name) = item;
                                    break :blk comp;
                                } else item;

                                const res = if (takes_allocator)
                                    service.execute(alloc, input_arg)
                                else
                                    service.execute(input_arg);

                                if (res) |val| {
                                    out_slice[written] = val;
                                    written += 1;
                                } else |err| {
                                    if (is_skip or is_collect) {
                                        ctx.logWarnFmt("Task '{s}' item {d} skipped on error: {s}", .{ spec.name, i, @errorName(err) });
                                        continue;
                                    }
                                    ctx.logErrorFmt("Task '{s}' item {d} failed: {s}", .{ spec.name, i, @errorName(err) });
                                    return .fatal_error;
                                }
                            }
                            ctx.emitTypedSlice(null, ElemType, out_slice[0..written]) catch |err| {
                                ctx.logErrorFmt("Task '{s}' failed to emit mapped slice: {s}", .{ spec.name, @errorName(err) });
                                return .fatal_error;
                            };
                            return .ok;
                        }
                    }

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

                    // 5. Auto-emit typed output (single struct, slice of structs, or multi-channel Channels(T))
                    if (PayloadOut == TaskStatus_ABI) {
                        return result;
                    } else if (PayloadOut == void) {
                        return .ok;
                    } else if (@typeInfo(PayloadOut) == .@"struct" and @hasDecl(PayloadOut, "is_flowdata_channels")) {
                        const Inner = PayloadOut.ChannelsType;
                        const inner_info = @typeInfo(Inner);
                        inline for (inner_info.@"struct".fields) |f| {
                            const val = @field(result.data, f.name);
                            const FType = f.type;
                            const f_key_z: [:0]const u8 = (f.name ++ "\x00")[0..f.name.len :0];
                            if (@typeInfo(FType) == .pointer and @typeInfo(FType).pointer.size == .slice) {
                                ctx.emitTypedSlice(f_key_z, @typeInfo(FType).pointer.child, val) catch |err| {
                                    ctx.logErrorFmt("Task '{s}' failed to emit slice to channel '{s}': {s}", .{ spec.name, f.name, @errorName(err) });
                                    return .fatal_error;
                                };
                            } else {
                                ctx.emitTypedRowTo(f_key_z, val) catch |err| {
                                    ctx.logErrorFmt("Task '{s}' failed to emit row to channel '{s}': {s}", .{ spec.name, f.name, @errorName(err) });
                                    return .fatal_error;
                                };
                            }
                        }
                        return .ok;
                    } else if (is_slice) {
                        // Prefer zero-copy emitTypedSlice over ABI
                        ctx.emitTypedSlice(null, ElemType, result) catch {
                            // Fallback to emitTypedRow row-by-row if emit_typed_slice not supported
                            for (result) |item| {
                                ctx.emitTypedRow(item) catch |err| {
                                    ctx.logErrorFmt("Task '{s}' failed to emit output row: {s}", .{ spec.name, @errorName(err) });
                                    return .fatal_error;
                                };
                            }
                        };
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

            var flags: u32 = TaskDescriptor_ABI.FLAG_CONCURRENCY_SAFE;
            if (@hasField(@TypeOf(spec), "lift")) {
                if (spec.lift == .elemental) {
                    flags |= TaskDescriptor_ABI.FLAG_LIFT_ELEMENTAL;
                }
            }
            if (@hasField(@TypeOf(spec), "passthrough")) {
                if (spec.passthrough) {
                    flags |= TaskDescriptor_ABI.FLAG_PASSTHROUGH;
                }
            }

            return .{
                .task_name = spec.name.ptr,
                .description = description_z.ptr,
                .output_fields_ptr = if (computed_output_fields.len > 0) computed_output_fields.ptr else null,
                .output_fields_len = computed_output_fields.len,
                .required_params_ptr = if (required_params.len > 0) required_params.ptr else null,
                .required_params_len = required_params.len,
                .execute = &Trampoline.execute,
                .flags = flags,
            };
        }
    };
}

/// Default DI Container for simple tasks requiring only built-in SDK dependencies.
pub const DefaultDiContainer = DiContainer(EmptyContext);
pub const defineTaskService = DefaultDiContainer.defineTaskService;
