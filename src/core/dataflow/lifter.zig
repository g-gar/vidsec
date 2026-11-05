const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const PayloadHandle = types.PayloadHandle;
const parallel = @import("parallel.zig");

pub const LifterError = error{
    OutOfMemory,
    CardinalityMismatch,
    TaskExecutionFailed,
    ThreadSpawnFailed,
    WorkerTaskFailed,
};

/// Runtime execution options controlling concurrency and thread budgets.
pub const ExecutionOptions = struct {
    /// Number of worker threads for data parallelism.
    /// Default `1` enforces strict single-threaded deterministic execution.
    workers: usize = 1,
};

/// Type-erased polymorphic task function signature usable by DAG engines.
pub const ErasedTaskFn = *const fn (allocator: Allocator, in: PayloadHandle, options: ExecutionOptions) anyerror!PayloadHandle;

/// Wraps a native elemental task (1 -> 1) into an erased task function with
/// automatic lifting over streams (N -> N) and optional chunked data parallelism.
pub fn wrapElemental(
    comptime In: type,
    comptime Out: type,
    comptime func: fn (Allocator, In) anyerror!Out,
) ErasedTaskFn {
    const Wrapper = struct {
        fn call(allocator: Allocator, in_payload: PayloadHandle, options: ExecutionOptions) anyerror!PayloadHandle {
            if (in_payload.is_stream) {
                const in_items = in_payload.asSlice(In);
                const out_items = try allocator.alloc(Out, in_items.len);
                errdefer allocator.free(out_items);

                const ChunkCtx = struct {
                    alloc: Allocator,
                    inputs: []const In,
                    outputs: []Out,

                    fn processChunk(self: @This(), start: usize, end: usize) anyerror!void {
                        for (self.inputs[start..end], start..) |item, i| {
                            self.outputs[i] = try func(self.alloc, item);
                        }
                    }
                };

                const ctx = ChunkCtx{
                    .alloc = allocator,
                    .inputs = in_items,
                    .outputs = out_items,
                };

                try parallel.parallelFor(allocator, options.workers, ChunkCtx, ctx, in_items.len, ChunkCtx.processChunk);
                return PayloadHandle.fromSlice(Out, out_items);
            } else {
                // Elemental scalar execution
                const in_item = in_payload.asScalar(In).*;
                const out_scalar = try allocator.create(Out);
                errdefer allocator.destroy(out_scalar);
                out_scalar.* = try func(allocator, in_item);
                return PayloadHandle.fromScalar(Out, out_scalar);
            }
        }
    };
    return Wrapper.call;
}

/// Wraps a native expansion task (1 -> N) into an erased task function with
/// automatic flattening over streams (N -> N*M) and optional chunked data parallelism.
pub fn wrapExpansion(
    comptime In: type,
    comptime Out: type,
    comptime func: fn (Allocator, In) anyerror![]const Out,
) ErasedTaskFn {
    const Wrapper = struct {
        fn call(allocator: Allocator, in_payload: PayloadHandle, options: ExecutionOptions) anyerror!PayloadHandle {
            if (in_payload.is_stream) {
                const in_items = in_payload.asSlice(In);

                if (options.workers <= 1 or in_items.len <= 1) {
                    var flattened: std.ArrayListUnmanaged(Out) = .empty;
                    errdefer flattened.deinit(allocator);

                    for (in_items) |item| {
                        const sub_stream = try func(allocator, item);
                        defer allocator.free(sub_stream);
                        try flattened.appendSlice(allocator, sub_stream);
                    }
                    return PayloadHandle.fromSlice(Out, try flattened.toOwnedSlice(allocator));
                } else {
                    // Parallel expansion preserving deterministic concatenation order
                    const SubResults = struct {
                        alloc: Allocator,
                        inputs: []const In,
                        sub_slices: [][]const Out,

                        fn processChunk(self: @This(), start: usize, end: usize) anyerror!void {
                            for (self.inputs[start..end], start..) |item, i| {
                                self.sub_slices[i] = try func(self.alloc, item);
                            }
                        }
                    };

                    const sub_slices = try allocator.alloc([]const Out, in_items.len);
                    defer allocator.free(sub_slices);

                    const ctx = SubResults{
                        .alloc = allocator,
                        .inputs = in_items,
                        .sub_slices = sub_slices,
                    };

                    try parallel.parallelFor(allocator, options.workers, SubResults, ctx, in_items.len, SubResults.processChunk);

                    var total_count: usize = 0;
                    for (sub_slices) |sub| total_count += sub.len;

                    const merged = try allocator.alloc(Out, total_count);
                    errdefer allocator.free(merged);

                    var offset: usize = 0;
                    for (sub_slices) |sub| {
                        @memcpy(merged[offset .. offset + sub.len], sub);
                        offset += sub.len;
                        allocator.free(sub);
                    }

                    return PayloadHandle.fromSlice(Out, merged);
                }
            } else {
                const in_item = in_payload.asScalar(In).*;
                const out_stream = try func(allocator, in_item);
                return PayloadHandle.fromSlice(Out, out_stream);
            }
        }
    };
    return Wrapper.call;
}

/// Wraps a native reduction task (N -> 1) into an erased task function.
pub fn wrapReduction(
    comptime In: type,
    comptime Out: type,
    comptime func: fn (Allocator, []const In) anyerror!Out,
) ErasedTaskFn {
    const Wrapper = struct {
        fn call(allocator: Allocator, in_payload: PayloadHandle, _: ExecutionOptions) anyerror!PayloadHandle {
            const in_items = in_payload.asSlice(In);
            const out_scalar = try allocator.create(Out);
            errdefer allocator.destroy(out_scalar);
            out_scalar.* = try func(allocator, in_items);
            return PayloadHandle.fromScalar(Out, out_scalar);
        }
    };
    return Wrapper.call;
}

/// Wraps a native batch transformation task (N -> M) into an erased task function.
pub fn wrapBatch(
    comptime In: type,
    comptime Out: type,
    comptime func: fn (Allocator, []const In) anyerror![]const Out,
) ErasedTaskFn {
    const Wrapper = struct {
        fn call(allocator: Allocator, in_payload: PayloadHandle, _: ExecutionOptions) anyerror!PayloadHandle {
            const in_items = in_payload.asSlice(In);
            const out_stream = try func(allocator, in_items);
            return PayloadHandle.fromSlice(Out, out_stream);
        }
    };
    return Wrapper.call;
}
