const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParallelError = error{
    OutOfMemory,
    ThreadSpawnFailed,
    WorkerTaskFailed,
};

/// Executes `worker_fn` over chunks of range `0..total_items` across up to `workers` threads.
/// When `workers <= 1` or `total_items <= 1`, executes synchronously in the caller thread with zero overhead.
/// Propagates any error encountered by worker threads.
pub fn parallelFor(
    allocator: Allocator,
    workers: usize,
    comptime Context: type,
    ctx: Context,
    total_items: usize,
    comptime worker_fn: fn (Context, start: usize, end: usize) anyerror!void,
) ParallelError!void {
    if (total_items == 0) return;

    if (workers <= 1 or total_items <= 1) {
        worker_fn(ctx, 0, total_items) catch return error.WorkerTaskFailed;
        return;
    }

    const num_threads = @min(workers, total_items);
    const chunk_size = (total_items + num_threads - 1) / num_threads;

    const WorkerState = struct {
        ctx: Context,
        start: usize,
        end: usize,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            worker_fn(self.ctx, self.start, self.end) catch |e| {
                self.err = e;
            };
        }
    };

    const states = allocator.alloc(WorkerState, num_threads) catch return error.OutOfMemory;
    defer allocator.free(states);

    const threads = allocator.alloc(std.Thread, num_threads) catch return error.OutOfMemory;
    defer allocator.free(threads);

    var spawned: usize = 0;
    errdefer {
        for (threads[0..spawned]) |t| t.join();
    }

    var start: usize = 0;
    while (start < total_items) : (spawned += 1) {
        const end = @min(start + chunk_size, total_items);
        states[spawned] = .{
            .ctx = ctx,
            .start = start,
            .end = end,
        };
        threads[spawned] = std.Thread.spawn(.{}, WorkerState.run, .{&states[spawned]}) catch return error.ThreadSpawnFailed;
        start = end;
    }

    var encountered_error: ?anyerror = null;
    for (threads[0..spawned]) |t| {
        t.join();
    }

    for (states[0..spawned]) |s| {
        if (s.err) |e| {
            encountered_error = e;
        }
    }

    if (encountered_error != null) {
        return error.WorkerTaskFailed;
    }
}
