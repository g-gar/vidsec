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
            comptime {
                @setEvalBranchQuota(10000);
                di.assertValidService(ContextImpl, Service);
            }

            const ExecFnType = @TypeOf(Service.execute);
            const fn_info = @typeInfo(ExecFnType).@"fn";

            const Inputs = deduceServiceInputsType(Service, ExecFnType);
            const has_inputs = (Inputs != void);
            const takes_allocator = fn_info.params.len >= 2 and fn_info.params[1].type.? == Allocator;

            const required_params = if (has_inputs)
                input_injector.computeRequiredParams(Inputs)
            else
                &.{};
            const required_input_fields = if (has_inputs)
                input_injector.computeRequiredInputFields(Inputs)
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
                        const is_fail_fast = !is_skip and !is_collect;

                        const ItemError = @import("../types/item_error.zig").ItemError;

                        const ErrorCollector = struct {
                            policy_fail_fast: bool,
                            policy_collect: bool,
                            min_fail_idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(std.math.maxInt(usize)),
                            fail_err_name: [64]u8 = [_]u8{0} ** 64,
                            fail_err_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
                            cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                            collected_errors: []?ItemError,

                            fn recordError(self: *@This(), idx: usize, err: anyerror) void {
                                if (self.policy_fail_fast) {
                                    self.cancel_flag.store(true, .release);
                                    while (true) {
                                        const cur = self.min_fail_idx.load(.acquire);
                                        if (idx >= cur) break;
                                        if (self.min_fail_idx.cmpxchgWeak(cur, idx, .acq_rel, .acquire) == null) {
                                            const err_name = @errorName(err);
                                            const len = @min(err_name.len, self.fail_err_name.len);
                                            @memcpy(self.fail_err_name[0..len], err_name[0..len]);
                                            self.fail_err_len.store(len, .release);
                                            break;
                                        }
                                    }
                                }
                                if (self.policy_collect) {
                                    self.collected_errors[idx] = ItemError{
                                        .index = @intCast(idx),
                                        .error_name = @errorName(err),
                                        .message = "",
                                    };
                                }
                            }
                        };

                        var empty_err_buf = [0]?ItemError{};
                        const err_slots: []?ItemError = if (is_collect) blk: {
                            const s = alloc.alloc(?ItemError, in_items.len) catch return .fatal_error;
                            @memset(s, null);
                            break :blk s;
                        } else &empty_err_buf;

                        var err_collector = ErrorCollector{
                            .policy_fail_fast = is_fail_fast,
                            .policy_collect = is_collect,
                            .collected_errors = err_slots,
                        };

                        const workers_budget = ctx.workerCount();

                        // 6. Execute by cardinality across workers with dynamic compaction
                        if (is_optional) {
                            // Filter: 1 -> 0..1
                            const slots = alloc.alloc(?ElemType, in_items.len) catch return .fatal_error;
                            @memset(slots, null);

                            const FilterChunkCtx = struct {
                                items: []const ItemType,
                                slots: []?ElemType,
                                broadcast: Inputs,
                                srv: *Service,
                                task_ctx: TaskContext,
                                allocator: Allocator,
                                err_col: *ErrorCollector,

                                fn executeChunk(pctx: *@This(), start: usize, end: usize) u8 {
                                    for (start..end) |i| {
                                        if (pctx.err_col.cancel_flag.load(.acquire) or pctx.task_ctx.isCancelled()) return 1;
                                        const input_arg = if (is_composite_elemental) blk: {
                                            var comp = pctx.broadcast;
                                            @field(comp, elemental_field_name) = pctx.items[i];
                                            break :blk comp;
                                        } else pctx.items[i];

                                        const res = if (takes_allocator)
                                            pctx.srv.execute(pctx.allocator, input_arg)
                                        else
                                            pctx.srv.execute(input_arg);

                                        if (res) |maybe_item| {
                                            pctx.slots[i] = maybe_item;
                                        } else |err| {
                                            pctx.err_col.recordError(i, err);
                                            if (pctx.err_col.policy_fail_fast) return 1;
                                        }
                                    }
                                    return 0;
                                }
                            };

                            var chunk_ctx = FilterChunkCtx{
                                .items = in_items,
                                .slots = slots,
                                .broadcast = broadcast_inputs,
                                .srv = &service,
                                .task_ctx = ctx,
                                .allocator = alloc,
                                .err_col = &err_collector,
                            };

                            _ = ctx.parallelFor(in_items.len, workers_budget, FilterChunkCtx, &chunk_ctx, FilterChunkCtx.executeChunk) catch {};

                            if (ctx.isCancelled()) return .halt_pipeline;

                            if (is_fail_fast and err_collector.min_fail_idx.load(.acquire) != std.math.maxInt(usize)) {
                                const min_idx = err_collector.min_fail_idx.load(.acquire);
                                const err_name = err_collector.fail_err_name[0..err_collector.fail_err_len.load(.acquire)];
                                ctx.logErrorFmt("Task '{s}' item {d} failed: {s}", .{ spec.name, min_idx, err_name });
                                return .fatal_error;
                            }

                            // Compact filtered results in index order
                            var count: usize = 0;
                            for (slots) |s| {
                                if (s != null) count += 1;
                            }
                            var compacted = alloc.alloc(ElemType, count) catch return .fatal_error;
                            var w: usize = 0;
                            for (slots) |s| {
                                if (s) |val| {
                                    compacted[w] = val;
                                    w += 1;
                                }
                            }
                            ctx.emitTypedSlice(null, ElemType, compacted) catch |err| {
                                ctx.logErrorFmt("Task '{s}' failed to emit filtered slice: {s}", .{ spec.name, @errorName(err) });
                                return .fatal_error;
                            };

                            if (is_collect) {
                                var err_count: usize = 0;
                                for (err_slots) |e| if (e != null) {
                                    err_count += 1;
                                };
                                var compact_errs = alloc.alloc(ItemError, err_count) catch return .fatal_error;
                                var ew: usize = 0;
                                for (err_slots) |e| {
                                    if (e) |val| {
                                        compact_errs[ew] = val;
                                        ew += 1;
                                    }
                                }
                                ctx.emitTypedSlice("errors", ItemError, compact_errs) catch {};
                            }

                            return .ok;
                        } else if (is_slice) {
                            // Expansion: 1 -> M
                            const slots = alloc.alloc([]const ElemType, in_items.len) catch return .fatal_error;
                            @memset(slots, &.{});

                            const ExpandChunkCtx = struct {
                                items: []const ItemType,
                                slots: [][]const ElemType,
                                broadcast: Inputs,
                                srv: *Service,
                                task_ctx: TaskContext,
                                allocator: Allocator,
                                err_col: *ErrorCollector,

                                fn executeChunk(pctx: *@This(), start: usize, end: usize) u8 {
                                    for (start..end) |i| {
                                        if (pctx.err_col.cancel_flag.load(.acquire) or pctx.task_ctx.isCancelled()) return 1;
                                        const input_arg = if (is_composite_elemental) blk: {
                                            var comp = pctx.broadcast;
                                            @field(comp, elemental_field_name) = pctx.items[i];
                                            break :blk comp;
                                        } else pctx.items[i];

                                        const res = if (takes_allocator)
                                            pctx.srv.execute(pctx.allocator, input_arg)
                                        else
                                            pctx.srv.execute(input_arg);

                                        if (res) |slice_items| {
                                            pctx.slots[i] = slice_items;
                                        } else |err| {
                                            pctx.err_col.recordError(i, err);
                                            if (pctx.err_col.policy_fail_fast) return 1;
                                        }
                                    }
                                    return 0;
                                }
                            };

                            var chunk_ctx = ExpandChunkCtx{
                                .items = in_items,
                                .slots = slots,
                                .broadcast = broadcast_inputs,
                                .srv = &service,
                                .task_ctx = ctx,
                                .allocator = alloc,
                                .err_col = &err_collector,
                            };

                            _ = ctx.parallelFor(in_items.len, workers_budget, ExpandChunkCtx, &chunk_ctx, ExpandChunkCtx.executeChunk) catch {};

                            if (ctx.isCancelled()) return .halt_pipeline;

                            if (is_fail_fast and err_collector.min_fail_idx.load(.acquire) != std.math.maxInt(usize)) {
                                const min_idx = err_collector.min_fail_idx.load(.acquire);
                                const err_name = err_collector.fail_err_name[0..err_collector.fail_err_len.load(.acquire)];
                                ctx.logErrorFmt("Task '{s}' item {d} failed: {s}", .{ spec.name, min_idx, err_name });
                                return .fatal_error;
                            }

                            // Flatten slices in index order
                            var total_elements: usize = 0;
                            for (slots) |s| total_elements += s.len;
                            var flattened = alloc.alloc(ElemType, total_elements) catch return .fatal_error;
                            var offset: usize = 0;
                            for (slots) |s| {
                                if (s.len > 0) {
                                    @memcpy(flattened[offset .. offset + s.len], s);
                                    offset += s.len;
                                }
                            }
                            ctx.emitTypedSlice(null, ElemType, flattened) catch |err| {
                                ctx.logErrorFmt("Task '{s}' failed to emit expanded slice: {s}", .{ spec.name, @errorName(err) });
                                return .fatal_error;
                            };

                            if (is_collect) {
                                var err_count: usize = 0;
                                for (err_slots) |e| if (e != null) {
                                    err_count += 1;
                                };
                                var compact_errs = alloc.alloc(ItemError, err_count) catch return .fatal_error;
                                var ew: usize = 0;
                                for (err_slots) |e| {
                                    if (e) |val| {
                                        compact_errs[ew] = val;
                                        ew += 1;
                                    }
                                }
                                ctx.emitTypedSlice("errors", ItemError, compact_errs) catch {};
                            }

                            return .ok;
                        } else {
                            // Map: 1 -> 1
                            const slots = alloc.alloc(?ElemType, in_items.len) catch return .fatal_error;
                            @memset(slots, null);

                            const MapChunkCtx = struct {
                                items: []const ItemType,
                                slots: []?ElemType,
                                broadcast: Inputs,
                                srv: *Service,
                                task_ctx: TaskContext,
                                allocator: Allocator,
                                err_col: *ErrorCollector,

                                fn executeChunk(pctx: *@This(), start: usize, end: usize) u8 {
                                    for (start..end) |i| {
                                        if (pctx.err_col.cancel_flag.load(.acquire) or pctx.task_ctx.isCancelled()) return 1;
                                        const input_arg = if (is_composite_elemental) blk: {
                                            var comp = pctx.broadcast;
                                            @field(comp, elemental_field_name) = pctx.items[i];
                                            break :blk comp;
                                        } else pctx.items[i];

                                        const res = if (takes_allocator)
                                            pctx.srv.execute(pctx.allocator, input_arg)
                                        else
                                            pctx.srv.execute(input_arg);

                                        if (res) |val| {
                                            pctx.slots[i] = val;
                                        } else |err| {
                                            pctx.err_col.recordError(i, err);
                                            if (pctx.err_col.policy_fail_fast) return 1;
                                        }
                                    }
                                    return 0;
                                }
                            };

                            var chunk_ctx = MapChunkCtx{
                                .items = in_items,
                                .slots = slots,
                                .broadcast = broadcast_inputs,
                                .srv = &service,
                                .task_ctx = ctx,
                                .allocator = alloc,
                                .err_col = &err_collector,
                            };

                            _ = ctx.parallelFor(in_items.len, workers_budget, MapChunkCtx, &chunk_ctx, MapChunkCtx.executeChunk) catch {};

                            if (ctx.isCancelled()) return .halt_pipeline;

                            if (is_fail_fast and err_collector.min_fail_idx.load(.acquire) != std.math.maxInt(usize)) {
                                const min_idx = err_collector.min_fail_idx.load(.acquire);
                                const err_name = err_collector.fail_err_name[0..err_collector.fail_err_len.load(.acquire)];
                                ctx.logErrorFmt("Task '{s}' item {d} failed: {s}", .{ spec.name, min_idx, err_name });
                                return .fatal_error;
                            }

                            // Compact / extract items in index order
                            var count: usize = 0;
                            for (slots) |s| {
                                if (s != null) count += 1;
                            }
                            var compacted = alloc.alloc(ElemType, count) catch return .fatal_error;
                            var w: usize = 0;
                            for (slots) |s| {
                                if (s) |val| {
                                    compacted[w] = val;
                                    w += 1;
                                }
                            }
                            ctx.emitTypedSlice(null, ElemType, compacted) catch |err| {
                                ctx.logErrorFmt("Task '{s}' failed to emit mapped slice: {s}", .{ spec.name, @errorName(err) });
                                return .fatal_error;
                            };

                            if (is_collect) {
                                var err_count: usize = 0;
                                for (err_slots) |e| if (e != null) {
                                    err_count += 1;
                                };
                                var compact_errs = alloc.alloc(ItemError, err_count) catch return .fatal_error;
                                var ew: usize = 0;
                                for (err_slots) |e| {
                                    if (e) |val| {
                                        compact_errs[ew] = val;
                                        ew += 1;
                                    }
                                }
                                ctx.emitTypedSlice("errors", ItemError, compact_errs) catch {};
                            }

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

                pub fn canHandle(payload_abi: *const types.PayloadHandle_ABI) callconv(.c) bool {
                    if (comptime @hasDecl(Service, "canHandle")) {
                        const CanHandleFnType = @TypeOf(Service.canHandle);
                        const ch_info = @typeInfo(CanHandleFnType).@"fn";
                        if (comptime ch_info.params.len == 1) {
                            const P0 = ch_info.params[0].type.?;
                            if (P0 == *const types.PayloadHandle_ABI) {
                                return Service.canHandle(payload_abi);
                            } else {
                                return Service.canHandle(payload_abi.*);
                            }
                        } else if (comptime ch_info.params.len >= 2) {
                            var s = std.mem.zeroes(Service);
                            const P1 = ch_info.params[1].type.?;
                            if (P1 == *const types.PayloadHandle_ABI) {
                                return s.canHandle(payload_abi);
                            } else {
                                return s.canHandle(payload_abi.*);
                            }
                        }
                    }

                    // Automatic Structural Compatibility (ARCH-018 §3.1 Mode 1)
                    if (comptime Inputs == void) {
                        return true;
                    }

                    const expected_schema_id = comptime types.schemaId(Inputs);
                    if (payload_abi.schema_id != 0 and expected_schema_id != 0 and payload_abi.schema_id == expected_schema_id) {
                        return true;
                    }
                    if (comptime is_elemental) {
                        const item_schema_id = comptime types.schemaId(ItemType);
                        if (payload_abi.schema_id != 0 and item_schema_id != 0 and payload_abi.schema_id == item_schema_id) {
                            return true;
                        }
                    }

                    const in_info = @typeInfo(Inputs);
                    if (comptime in_info == .@"struct") {
                        inline for (in_info.@"struct".fields) |f| {
                            const has_default = (f.default_value_ptr != null);
                            if (!has_default) {
                                if (payload_abi.getReflected(f.name) == null) {
                                    return false;
                                }
                            }
                        }
                        return true;
                    }

                    return false;
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
                .can_handle = &Trampoline.canHandle,
                .input_fields_ptr = if (required_input_fields.len > 0) required_input_fields.ptr else null,
                .input_fields_len = required_input_fields.len,
            };
        }
    };
}

/// Default DI Container for simple tasks requiring only built-in SDK dependencies.
pub const DefaultDiContainer = DiContainer(EmptyContext);
pub const defineTaskService = DefaultDiContainer.defineTaskService;
