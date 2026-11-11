const std = @import("std");
const testing = std.testing;
const flowdata = @import("flowdata");
const extensions = @import("flowdata_extensions");
const concurrency = flowdata.concurrency;

const Mutex = concurrency.Mutex;
const Condition = concurrency.Condition;
const RwLock = concurrency.RwLock;
const WaitGroup = concurrency.WaitGroup;
const WorkerPool = concurrency.WorkerPool;

fn sleepNs(ns: u64) void {
    const sec: i64 = @intCast(ns / std.time.ns_per_s);
    const nsec: i64 = @intCast(ns % std.time.ns_per_s);
    const req = std.c.timespec{ .sec = sec, .nsec = nsec };
    _ = std.c.nanosleep(&req, null);
}

// ============================================================================
// 1. POSIX Sync Primitives: Mutex, Condition, RwLock, WaitGroup
// ============================================================================

test "Concurrency Contract: Mutex mutual exclusion under thread contention" {
    const thread_count = 16;
    const iters_per_thread = 1_000;

    const State = struct {
        mutex: Mutex = .{},
        counter: usize = 0,
    };

    var state = State{};
    var threads: [thread_count]std.Thread = undefined;

    const workerFn = struct {
        fn run(s: *State) void {
            var i: usize = 0;
            while (i < iters_per_thread) : (i += 1) {
                s.mutex.lock();
                s.counter += 1;
                s.mutex.unlock();
            }
        }
    }.run;

    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, workerFn, .{&state});
    }

    for (threads) |t| {
        t.join();
    }

    try testing.expectEqual(@as(usize, thread_count * iters_per_thread), state.counter);
    state.mutex.deinit();
}

test "Concurrency Contract: Condition variable timedWait and signal" {
    var mutex = Mutex.init();
    defer mutex.deinit();
    var cond = Condition.init();
    defer cond.deinit();

    // Test timedWait timeout expiration
    mutex.lock();
    const signaled = cond.timedWait(&mutex, 1_000_000); // 1 millisecond
    mutex.unlock();
    try testing.expect(!signaled); // Should timeout (return false)

    // Test signal waking a thread
    const State = struct {
        mutex: *Mutex,
        cond: *Condition,
        ready: bool = false,
    };
    var s = State{ .mutex = &mutex, .cond = &cond };

    const waiter = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *State) void {
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            while (!ctx.ready) {
                ctx.cond.wait(ctx.mutex);
            }
        }
    }.run, .{&s});

    // Short sleep before signaling
    sleepNs(1_000_000); // 1ms
    mutex.lock();
    s.ready = true;
    cond.signal();
    mutex.unlock();

    waiter.join();
    try testing.expect(s.ready);
}

test "Concurrency Contract: RwLock concurrent readers and exclusive writer" {
    var rwlock = RwLock.init();
    defer rwlock.deinit();

    const State = struct {
        lock: *RwLock,
        shared_value: u64 = 0,
        active_readers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        max_concurrent_readers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    };
    var s = State{ .lock = &rwlock };

    const readerFn = struct {
        fn run(ctx: *State) void {
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                ctx.lock.lockRead();
                const cur = ctx.active_readers.fetchAdd(1, .seq_cst) + 1;
                // Track peak concurrent readers
                var peak = ctx.max_concurrent_readers.load(.seq_cst);
                while (cur > peak) {
                    _ = ctx.max_concurrent_readers.cmpxchgWeak(peak, cur, .seq_cst, .seq_cst) orelse break;
                    peak = ctx.max_concurrent_readers.load(.seq_cst);
                }
                sleepNs(50_000); // 50 microseconds
                _ = ctx.shared_value;
                _ = ctx.active_readers.fetchSub(1, .seq_cst);
                ctx.lock.unlock();
            }
        }
    }.run;

    const writerFn = struct {
        fn run(ctx: *State) void {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                ctx.lock.lockWrite();
                // When holding write lock, there must be 0 active readers
                std.debug.assert(ctx.active_readers.load(.seq_cst) == 0);
                ctx.shared_value += 1;
                sleepNs(100_000); // 100 microseconds
                ctx.lock.unlock();
            }
        }
    }.run;

    var readers: [8]std.Thread = undefined;
    for (&readers) |*t| {
        t.* = try std.Thread.spawn(.{}, readerFn, .{&s});
    }

    var writer = try std.Thread.spawn(.{}, writerFn, .{&s});

    for (readers) |t| t.join();
    writer.join();

    try testing.expect(s.shared_value == 10);
    try testing.expect(s.max_concurrent_readers.load(.seq_cst) > 1);
}

test "Concurrency Contract: WaitGroup multi-worker coordination" {
    var wg = WaitGroup.init(4);
    const Worker = struct {
        fn run(w: *WaitGroup) void {
            sleepNs(100_000); // 100us
            w.done();
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{&wg});
    }

    wg.wait();
    try testing.expect(wg.isDone());

    for (threads) |t| t.join();
}

// ============================================================================
// 2. WorkerPool & parallelFor Execution
// ============================================================================

test "Concurrency Contract: WorkerPool basic task dispatch & node recycling" {
    const allocator = testing.allocator;
    var pool = try WorkerPool.init(allocator, 4);
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 4), pool.workerCount());

    const TaskCtx = struct {
        counter: std.atomic.Value(usize),
        wg: *WaitGroup,
    };

    const taskCount = 500;
    var wg = WaitGroup.init(taskCount);
    var ctx = TaskCtx{
        .counter = std.atomic.Value(usize).init(0),
        .wg = &wg,
    };

    const jobFn = struct {
        fn execute(raw: *anyopaque) void {
            const c: *TaskCtx = @ptrCast(@alignCast(raw));
            _ = c.counter.fetchAdd(1, .seq_cst);
            c.wg.done();
        }
    }.execute;

    var i: usize = 0;
    while (i < taskCount) : (i += 1) {
        try pool.submit(.{
            .run_fn = jobFn,
            .ctx = &ctx,
        });
    }

    wg.wait();
    try testing.expectEqual(@as(usize, taskCount), ctx.counter.load(.seq_cst));
}

test "Concurrency Contract: WorkerPool parallelFor computation & edge cases" {
    const allocator = testing.allocator;
    var pool = try WorkerPool.init(allocator, 4);
    defer pool.deinit();

    // 1. Regular large parallelFor
    const n = 10_000;
    const array = try allocator.alloc(u64, n);
    defer allocator.free(array);
    @memset(array, 0);

    const compute = struct {
        fn worker(arr: []u64, start: usize, end: usize) anyerror!void {
            for (start..end) |idx| {
                arr[idx] = @as(u64, idx * 2);
            }
        }
    }.worker;

    try pool.parallelFor(n, 4, []u64, array, compute);

    for (0..n) |idx| {
        try testing.expectEqual(@as(u64, idx * 2), array[idx]);
    }

    // 2. Edge case: 0 items
    try pool.parallelFor(0, 4, []u64, array, compute);

    // 3. Edge case: 1 item
    var single: [1]u64 = .{0};
    try pool.parallelFor(1, 4, []u64, &single, compute);
    try testing.expectEqual(@as(u64, 0), single[0]);

    // 4. Edge case: 3 items with 8 worker budget (fewer items than workers)
    var few: [3]u64 = .{ 0, 0, 0 };
    try pool.parallelFor(3, 8, []u64, &few, compute);
    try testing.expectEqual(@as(u64, 0), few[0]);
    try testing.expectEqual(@as(u64, 2), few[1]);
    try testing.expectEqual(@as(u64, 4), few[2]);

    // 5. Edge case: 5 items with 4 workers (rounding chunk size != effective_workers)
    var five: [5]u64 = .{ 0, 0, 0, 0, 0 };
    try pool.parallelFor(5, 4, []u64, &five, compute);
    for (0..5) |idx| {
        try testing.expectEqual(@as(u64, idx * 2), five[idx]);
    }
}

// ============================================================================
// 3. Nested Parallelism with Help-While-Waiting (Deadlock Elimination)
// ============================================================================

test "Concurrency Contract: Nested parallelism with helpWhile (ARCH-017 §7.7)" {
    // Specifically test: a pool of 2 workers running 4 concurrent parent tasks,
    // each spawning child work via parallelFor, must finish with zero deadlock.
    const allocator = testing.allocator;
    var pool = try WorkerPool.init(allocator, 2);
    defer pool.deinit();

    const parentCount = 4;
    const itemsPerParent = 20;

    var results = try allocator.alloc(u64, parentCount * itemsPerParent);
    defer allocator.free(results);
    @memset(results, 0);

    var parent_wg = WaitGroup.init(parentCount);

    const childKernel = struct {
        fn worker(slice: []u64, start: usize, end: usize) anyerror!void {
            for (start..end) |idx| {
                slice[idx] = 42;
                // Emulate slight delay to trigger concurrent scheduling
                sleepNs(20_000); // 20 microseconds
            }
        }
    }.worker;

    const parentJob = struct {
        fn run(raw: *anyopaque) void {
            const ctx: *struct {
                p: *WorkerPool,
                slice: []u64,
                wg: *WaitGroup,
            } = @ptrCast(@alignCast(raw));
            defer ctx.wg.done();

            // Spawn nested parallel execution using the SAME pool
            ctx.p.parallelFor(ctx.slice.len, 2, []u64, ctx.slice, childKernel) catch |err| {
                std.debug.panic("Child parallelFor failed: {}", .{err});
            };
        }
    }.run;

    const ParentState = struct {
        p: *WorkerPool,
        slice: []u64,
        wg: *WaitGroup,
    };
    var parent_states: [parentCount]ParentState = undefined;

    for (0..parentCount) |p_idx| {
        parent_states[p_idx] = .{
            .p = pool,
            .slice = results[p_idx * itemsPerParent .. (p_idx + 1) * itemsPerParent],
            .wg = &parent_wg,
        };
        try pool.submit(.{
            .run_fn = parentJob,
            .ctx = &parent_states[p_idx],
        });
    }

    // Main thread helps while waiting for parents to complete
    pool.helpWhile(&parent_wg);

    // Verify all child results computed without deadlock
    for (results) |val| {
        try testing.expectEqual(@as(u64, 42), val);
    }
}

// ============================================================================
// 4. DualTokenBucketStrategy Multi-Threaded Stress Test
// ============================================================================

test "Concurrency Contract: DualTokenBucketStrategy thread-safety under 16 concurrent threads" {
    const DualTokenBucketStrategy = flowdata.network.strategies.DualTokenBucketStrategy;

    var tb = DualTokenBucketStrategy.init(.{
        .requests_per_second = 1000.0,
        .burst = 2000,
        .max_bandwidth_mbps = 100.0,
    }, .{
        .max_connections = 64,
    }, 1000);

    const thread_count = 16;
    const iters = 200;

    const worker = struct {
        fn run(strat: *DualTokenBucketStrategy) void {
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const decision = strat.tryAcquire(1000 + i, 1024);
                switch (decision) {
                    .allowed => {
                        // Hold connection briefly
                        sleepNs(10_000); // 10us
                        strat.releaseInflight();
                    },
                    else => {
                        // Rate limit backoff
                        sleepNs(50_000);
                    },
                }
            }
        }
    }.run;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{&tb});
    }

    for (threads) |t| t.join();

    // After all threads finish and release, in-flight must be 0 and never negative
    try testing.expectEqual(@as(usize, 0), tb.activeInflight());
}

// ============================================================================
// 5. MemoryRepository Concurrent Multi-Channel Stress Test
// ============================================================================

test "Concurrency Contract: MemoryRepository concurrent multi-channel read/write" {
    const MemoryRepository = extensions.datasource.MemoryRepository;
    const allocator = testing.allocator;

    var repo = MemoryRepository.init(allocator);
    defer repo.deinit();

    const thread_count = 8;
    const iters = 100;

    const worker = struct {
        fn run(r: *MemoryRepository, thread_id: usize) void {
            var buf: [32]u8 = undefined;
            const channel = std.fmt.bufPrint(&buf, "chan_{d}", .{thread_id % 4}) catch unreachable;

            var i: usize = 0;
            while (i < iters) : (i += 1) {
                // Write payload
                var payload_buf: [32]u8 = undefined;
                const payload = std.fmt.bufPrint(&payload_buf, "val_{d}_{d}", .{ thread_id, i }) catch unreachable;
                const handle = flowdata.dataflow.PayloadHandle.fromSlice(u8, payload);
                r.writePayload(channel, handle) catch unreachable;

                // Read payload
                _ = r.readPayload(channel);
            }
        }
    }.run;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, worker, .{ &repo, idx });
    }

    for (threads) |t| t.join();

    // Verify all 4 channels have recorded payloads
    for (0..4) |c_idx| {
        var buf: [32]u8 = undefined;
        const channel = try std.fmt.bufPrint(&buf, "chan_{d}", .{c_idx});
        try testing.expect(repo.recordCount(channel) > 0);
    }
}

// ============================================================================
// 6. EngineNetworkController Concurrent Stream Operations
// ============================================================================

test "Concurrency Contract: EngineNetworkController concurrent stream table" {
    const EngineNetworkController = flowdata.EngineNetworkController;
    const allocator = testing.allocator;

    const ast = flowdata.PipelineAST{};
    var net = try EngineNetworkController.init(allocator, ast, null);
    defer net.deinit();

    const MockAdapter = struct {
        fn execute(ctx: *anyopaque, u: []const u8, op: []const u8, h: []const flowdata.network.HttpHeader, b: []const u8, t: []const u8) flowdata.network.NetError!flowdata.network.NetResult {
            _ = ctx; _ = u; _ = op; _ = h; _ = b; _ = t;
            return error.UnsupportedProtocolScheme;
        }
        fn connectStream(ctx: *anyopaque, u: []const u8, op: []const u8, t: []const u8) flowdata.network.NetError!flowdata.network.NetStreamId {
            _ = ctx; _ = u; _ = op; _ = t;
            return 1;
        }
        fn streamSend(ctx: *anyopaque, sid: flowdata.network.NetStreamId, p: []const u8) flowdata.network.NetError!usize {
            _ = ctx; _ = sid; return p.len;
        }
        fn streamRecv(ctx: *anyopaque, sid: flowdata.network.NetStreamId, dest: []u8) flowdata.network.NetError!usize {
            _ = ctx; _ = sid; _ = dest; return 0;
        }
        fn streamClose(ctx: *anyopaque, sid: flowdata.network.NetStreamId) void {
            _ = ctx; _ = sid;
        }
        fn capturedRecordsSlice(ctx: *const anyopaque) []const flowdata.network.CapturedExchangeRecord {
            _ = ctx; return &.{};
        }
        fn pcapBytes(ctx: *const anyopaque) ?[]const u8 {
            _ = ctx; return null;
        }
        fn metrics(ctx: *const anyopaque) flowdata.network.AdapterMetrics {
            _ = ctx; return .{};
        }
        fn advanceClockMs(ctx: *anyopaque, d: u64) void {
            _ = ctx; _ = d;
        }
        fn setTransportHandler(ctx: *anyopaque, u: ?*anyopaque, h: flowdata.network.CustomTransportFn) void {
            _ = ctx; _ = u; _ = h;
        }
        fn deinit(ctx: *anyopaque) void {
            _ = ctx;
        }

        const vtable = flowdata.network.NetworkAdapter.VTable{
            .execute = execute,
            .connectStream = connectStream,
            .streamSend = streamSend,
            .streamRecv = streamRecv,
            .streamClose = streamClose,
            .capturedRecordsSlice = capturedRecordsSlice,
            .pcapBytes = pcapBytes,
            .metrics = metrics,
            .advanceClockMs = advanceClockMs,
            .setTransportHandler = setTransportHandler,
            .deinit = deinit,
        };

        var dummy: usize = 0;
        fn adapter() flowdata.network.NetworkAdapter {
            return .{
                .ptr = &dummy,
                .vtable = &vtable,
            };
        }
    };

    const thread_count = 8;
    const iters = 50;

    const worker = struct {
        fn run(n: *EngineNetworkController, thread_id: usize) void {
            _ = thread_id;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const stream_id = n.connectStream("step1", "task1", MockAdapter.adapter(), "default", "tcp://127.0.0.1:8080", "CONNECT") catch continue;

                // Send
                _ = n.sendStream(stream_id, "PING") catch {};

                // Recv
                var recv_buf: [64]u8 = undefined;
                _ = n.recvStream(stream_id, &recv_buf) catch {};

                // Close
                _ = n.closeStream(stream_id) catch {};
            }
        }
    }.run;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, worker, .{ &net, idx });
    }

    for (threads) |t| t.join();
}

// ============================================================================
// 7. TelemetryBus Concurrent Emission
// ============================================================================

test "Concurrency Contract: TelemetryBus concurrent event emission" {
    const TelemetryBus = flowdata.TelemetryBus;
    const TelemetryEvent = flowdata.TelemetryEvent;
    const TelemetrySubscriber = flowdata.kernel.TelemetrySubscriber;
    const allocator = testing.allocator;

    var bus = TelemetryBus.init(allocator);
    defer bus.deinit();

    const Sink = struct {
        received_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn onEvent(ctx: *anyopaque, ev: *const TelemetryEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = ev;
            _ = self.received_count.fetchAdd(1, .seq_cst);
        }

        const vtable = TelemetrySubscriber.VTable{
            .onEvent = onEvent,
        };

        fn subscriber(self: *@This()) TelemetrySubscriber {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }
    };

    var sink = Sink{};
    try bus.subscribe(sink.subscriber());

    const thread_count = 8;
    const iters = 100;

    const worker = struct {
        fn run(b: *TelemetryBus) void {
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                b.emit(.{
                    .step_start = .{
                        .trace_id = [_]u8{0} ** 16,
                        .span_id = [_]u8{0} ** 8,
                        .parent_span_id = [_]u8{0} ** 8,
                        .timestamp_ns = 12345,
                        .pipeline_name = "test",
                        .step_id = "step1",
                        .module_name = "mod",
                        .task_name = "task",
                        .input_count = 0,
                    },
                });
            }
        }
    }.run;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{&bus});
    }

    for (threads) |t| t.join();

    try testing.expectEqual(@as(usize, thread_count * iters), sink.received_count.load(.seq_cst));
}
