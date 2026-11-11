const std = @import("std");
const Allocator = std.mem.Allocator;
const sync = @import("sync.zig");
const Mutex = sync.Mutex;
const Condition = sync.Condition;
const WaitGroup = sync.WaitGroup;

pub const Job = struct {
    run_fn: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,

    pub fn run(self: Job) void {
        self.run_fn(self.ctx);
    }
};

const JobNode = struct {
    job: Job,
    next: ?*JobNode = null,
};

/// Bounded worker pool with work-stealing / help-while-waiting semantics (ARCH-017 §3.2 & §4).
/// Prevents thread starvation and deadlock under nested task parallelism by allowing
/// waiting threads to actively drain work from the shared queue.
pub const WorkerPool = struct {
    allocator: Allocator,
    threads: []std.Thread,
    mutex: Mutex = .{},
    cond: Condition = .{},
    queue_head: ?*JobNode = null,
    queue_tail: ?*JobNode = null,
    free_head: ?*JobNode = null,
    shutdown: bool = false,

    pub fn init(allocator: Allocator, thread_count: usize) !*WorkerPool {
        const pool = try allocator.create(WorkerPool);
        pool.* = .{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, thread_count),
        };

        var spawned: usize = 0;
        errdefer {
            pool.mutex.lock();
            pool.shutdown = true;
            pool.cond.broadcast();
            pool.mutex.unlock();
            for (pool.threads[0..spawned]) |t| t.join();
            allocator.free(pool.threads);
            allocator.destroy(pool);
        }

        while (spawned < thread_count) : (spawned += 1) {
            pool.threads[spawned] = try std.Thread.spawn(.{}, workerThreadFn, .{pool});
        }

        return pool;
    }

    pub fn deinit(self: *WorkerPool) void {
        self.mutex.lock();
        self.shutdown = true;
        self.cond.broadcast();
        self.mutex.unlock();

        for (self.threads) |t| {
            t.join();
        }
        self.allocator.free(self.threads);

        // Free pending queue nodes
        var curr = self.queue_head;
        while (curr) |n| {
            curr = n.next;
            self.allocator.destroy(n);
        }

        // Free recycled node pool
        var free_curr = self.free_head;
        while (free_curr) |n| {
            free_curr = n.next;
            self.allocator.destroy(n);
        }

        self.mutex.deinit();
        self.cond.deinit();
        self.allocator.destroy(self);
    }

    pub fn workerCount(self: *const WorkerPool) usize {
        return self.threads.len;
    }

    /// Submits a task to the pool.
    pub fn submit(self: *WorkerPool, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutdown) return error.PoolShuttingDown;

        var node: *JobNode = undefined;
        if (self.free_head) |recycled| {
            self.free_head = recycled.next;
            node = recycled;
        } else {
            node = try self.allocator.create(JobNode);
        }

        node.job = job;
        node.next = null;

        if (self.queue_tail) |tail| {
            tail.next = node;
            self.queue_tail = node;
        } else {
            self.queue_head = node;
            self.queue_tail = node;
        }

        self.cond.signal();
    }

    /// Pops a job from the queue if available, without blocking.
    pub fn popJob(self: *WorkerPool) ?Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        const node = self.queue_head orelse return null;
        self.queue_head = node.next;
        if (self.queue_head == null) {
            self.queue_tail = null;
        }

        const job = node.job;
        node.next = self.free_head;
        self.free_head = node;

        return job;
    }

    /// Worker thread main loop.
    fn workerThreadFn(self: *WorkerPool) void {
        while (true) {
            self.mutex.lock();
            while (self.queue_head == null and !self.shutdown) {
                self.cond.wait(&self.mutex);
            }

            if (self.shutdown and self.queue_head == null) {
                self.mutex.unlock();
                return;
            }

            const node = self.queue_head.?;
            self.queue_head = node.next;
            if (self.queue_head == null) {
                self.queue_tail = null;
            }

            const job = node.job;
            node.next = self.free_head;
            self.free_head = node;
            self.mutex.unlock();

            job.run();
        }
    }

    /// Actively helps execute jobs from the pool until the given `WaitGroup` is completed.
    /// Eliminates idle blocking and deadlock when tasks spawn child parallel jobs.
    pub fn helpWhile(self: *WorkerPool, wg: *WaitGroup) void {
        while (!wg.isDone()) {
            if (self.popJob()) |job| {
                job.run();
            } else {
                if (wg.isDone()) break;
                // Brief pause waiting on wait group signal or queue work
                wg.mutex.lock();
                if (!wg.isDone()) {
                    _ = wg.cond.timedWait(&wg.mutex, 100_000); // 100 microseconds
                }
                wg.mutex.unlock();
            }
        }
    }

    /// Executes `worker_fn` over `total_items` chunked across up to `workers_budget` threads,
    /// participating in the work on the calling thread via `helpWhile`.
    pub fn parallelFor(
        self: *WorkerPool,
        total_items: usize,
        workers_budget: usize,
        comptime Context: type,
        ctx: Context,
        comptime worker_fn: fn (Context, start: usize, end: usize) anyerror!void,
    ) !void {
        if (total_items == 0) return;

        const effective_workers = @max(1, @min(workers_budget, @min(total_items, self.threads.len + 1)));
        if (effective_workers <= 1 or total_items <= 1) {
            try worker_fn(ctx, 0, total_items);
            return;
        }

        const ChunkState = struct {
            ctx: Context,
            start: usize,
            end: usize,
            wg: *WaitGroup,
            err: ?anyerror = null,

            fn execute(raw: *anyopaque) void {
                const s: *@This() = @ptrCast(@alignCast(raw));
                defer s.wg.done();
                worker_fn(s.ctx, s.start, s.end) catch |e| {
                    s.err = e;
                };
            }
        };

        const chunk_size = (total_items + effective_workers - 1) / effective_workers;
        const num_chunks = (total_items + chunk_size - 1) / chunk_size;
        const states = try self.allocator.alloc(ChunkState, num_chunks);
        defer self.allocator.free(states);

        var wg = WaitGroup.init(num_chunks);

        var start: usize = 0;
        var chunk_idx: usize = 0;
        while (start < total_items) : (chunk_idx += 1) {
            const end = @min(start + chunk_size, total_items);
            states[chunk_idx] = .{
                .ctx = ctx,
                .start = start,
                .end = end,
                .wg = &wg,
            };

            // Keep the last chunk for the caller thread to process immediately
            if (chunk_idx + 1 < num_chunks) {
                try self.submit(.{
                    .run_fn = &ChunkState.execute,
                    .ctx = &states[chunk_idx],
                });
            } else {
                // Caller thread processes this chunk
                ChunkState.execute(&states[chunk_idx]);
                break;
            }
            start = end;
        }

        // Help drain pool jobs until all chunks in this batch finish
        self.helpWhile(&wg);

        // Check for any chunk errors
        for (states[0 .. chunk_idx + 1]) |s| {
            if (s.err) |e| return e;
        }
    }
};
