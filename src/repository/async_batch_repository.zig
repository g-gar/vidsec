const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const concurrency = @import("../concurrency/mod.zig");
const Mutex = concurrency.Mutex;
const Condition = concurrency.Condition;
const storage = @import("storage_repository.zig");
const Repository = storage.Repository;
const ConfigParam = storage.ConfigParam;
const specs = @import("specs.zig");
const capabilities_mod = @import("capabilities.zig");
const RowIterator = @import("row_iterator.zig").RowIterator;

/// `AsyncBatchRepository` — Concurrency Decorator (ARCH-009A §2.5)
///
/// Wraps any `Repository` with a bounded MPSC queue and a dedicated background
/// writer thread. Pipeline workers push `WriteSpec`s asynchronously under
/// bounded-queue backpressure; the background writer drains batches and flushes
/// them inside a single transaction (`beginTx` / `commit` / `rollback`).
///
/// Read operations (`read`, `readStream`, `recordCount`, `readPayload`) flush
/// any pending writes before delegating to `inner` to guarantee read-your-own-writes
/// consistency.
pub const AsyncBatchRepository = struct {
    pub const Options = struct {
        /// Maximum number of queued `WriteSpec` items before producers block.
        capacity: usize = 256,
        /// Maximum number of `WriteSpec` items flushed per transaction batch.
        batch_size: usize = 64,
    };

    const QueuedWrite = struct {
        spec: specs.WriteSpec,
        owned_table: []u8,
    };

    inner: Repository,
    allocator: Allocator,
    options: Options,

    mutex: Mutex = .{},
    not_empty: Condition = .{},
    not_full: Condition = .{},
    drained: Condition = .{},

    queue: std.ArrayListUnmanaged(QueuedWrite) = .empty,
    in_flight: usize = 0,
    stopping: bool = false,
    started: bool = false,
    worker_thread: ?std.Thread = null,
    last_error: ?anyerror = null,

    pub fn init(allocator: Allocator, inner: Repository, options: Options) AsyncBatchRepository {
        return .{
            .inner = inner,
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn start(self: *AsyncBatchRepository) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.started) return;
        self.started = true;
        self.worker_thread = try std.Thread.spawn(.{}, writerLoop, .{self});
    }

    /// Blocks until all queued writes have been flushed to `inner`.
    /// Propagates any asynchronous write error recorded by the background thread.
    pub fn flush(self: *AsyncBatchRepository) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.items.len > 0 or self.in_flight > 0) {
            self.drained.wait(&self.mutex);
        }

        if (self.last_error) |err| {
            self.last_error = null;
            return err;
        }
    }

    pub fn deinit(self: *AsyncBatchRepository) void {
        self.mutex.lock();
        self.stopping = true;
        self.not_empty.broadcast();
        self.not_full.broadcast();
        const thread = self.worker_thread;
        self.worker_thread = null;
        self.mutex.unlock();

        if (thread) |t| {
            t.join();
        }

        // Free any remaining items if thread never started
        for (self.queue.items) |item| {
            self.allocator.free(item.owned_table);
        }
        self.queue.deinit(self.allocator);
        self.inner.deinit();
    }

    pub fn repository(self: *AsyncBatchRepository) Repository {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn enqueueWrite(self: *AsyncBatchRepository, ws: specs.WriteSpec) !void {
        if (!self.started) {
            try self.start();
        }

        const owned_table = try self.allocator.dupe(u8, ws.table);
        errdefer self.allocator.free(owned_table);

        var owned_spec = ws;
        owned_spec.table = owned_table;

        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.items.len >= self.options.capacity and !self.stopping) {
            self.not_full.wait(&self.mutex);
        }

        if (self.stopping) {
            self.allocator.free(owned_table);
            return error.RepositoryStopped;
        }

        if (self.last_error) |err| {
            self.last_error = null;
            self.allocator.free(owned_table);
            return err;
        }

        try self.queue.append(self.allocator, .{
            .spec = owned_spec,
            .owned_table = owned_table,
        });
        self.not_empty.signal();
    }

    fn writerLoop(self: *AsyncBatchRepository) void {
        var batch: std.ArrayListUnmanaged(QueuedWrite) = .empty;
        defer batch.deinit(self.allocator);

        while (true) {
            self.mutex.lock();
            while (self.queue.items.len == 0 and !self.stopping) {
                self.not_empty.wait(&self.mutex);
            }

            if (self.queue.items.len == 0 and self.stopping) {
                self.mutex.unlock();
                break;
            }

            const take_n = @min(self.queue.items.len, self.options.batch_size);
            batch.clearRetainingCapacity();
            batch.appendSlice(self.allocator, self.queue.items[0..take_n]) catch {
                self.last_error = error.OutOfMemory;
                self.mutex.unlock();
                continue;
            };

            // Shift remaining items forward
            const remaining = self.queue.items.len - take_n;
            if (remaining > 0) {
                std.mem.copyForwards(QueuedWrite, self.queue.items[0..remaining], self.queue.items[take_n..]);
            }
            self.queue.items.len = remaining;
            self.in_flight = take_n;
            self.not_full.broadcast();
            self.mutex.unlock();

            // Flush batch outside the queue lock
            const flush_err = self.flushBatch(batch.items);

            for (batch.items) |item| {
                self.allocator.free(item.owned_table);
            }

            self.mutex.lock();
            self.in_flight = 0;
            if (flush_err) |_| {} else |err| {
                if (self.last_error == null) self.last_error = err;
            }
            if (self.queue.items.len == 0) {
                self.drained.broadcast();
            }
            self.mutex.unlock();
        }
    }

    fn flushBatch(self: *AsyncBatchRepository, items: []const QueuedWrite) anyerror!void {
        const has_tx = self.inner.getCapabilities().transactions;
        if (has_tx) try self.inner.beginTx();
        errdefer if (has_tx) {
            self.inner.rollback() catch {};
        };

        for (items) |item| {
            try self.inner.write(item.spec);
        }

        if (has_tx) try self.inner.commit();
    }

    // ── VTable trampolines ────────────────────────────────────────────────────

    fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        try self.enqueueWrite(.{
            .table = channel,
            .mode = .upsert,
            .payload = payload,
        });
    }

    fn doWritePayloadWithParams(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle, params: []const ConfigParam) anyerror!void {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        try self.flush();
        try self.inner.writePayloadWithParams(channel, payload, params);
    }

    fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        self.flush() catch return null;
        return self.inner.readPayload(channel);
    }

    fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        self.flush() catch return 0;
        return self.inner.recordCount(channel);
    }

    fn doDeinit(ctx: *anyopaque) void {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn doGetCapabilities(ctx: *const anyopaque) capabilities_mod.Capabilities {
        const self: *const AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        return self.inner.getCapabilities();
    }

    fn doEnsureSchema(ctx: *anyopaque, catalog: *const anyopaque) anyerror!void {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        try self.flush();
        try self.inner.ensureSchema(catalog);
    }

    fn doWrite(ctx: *anyopaque, ws: specs.WriteSpec) anyerror!void {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        try self.enqueueWrite(ws);
    }

    fn doRead(ctx: *anyopaque, allocator: Allocator, rs: specs.ReadSpec) anyerror!PayloadHandle {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        try self.flush();
        return self.inner.read(allocator, rs);
    }

    fn doReadStream(ctx: *anyopaque, allocator: Allocator, rs: specs.ReadSpec) anyerror!RowIterator {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        try self.flush();
        return self.inner.readStream(allocator, rs);
    }

    fn doBeginTx(ctx: *anyopaque) anyerror!void {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        try self.flush();
        try self.inner.beginTx();
    }

    fn doCommit(ctx: *anyopaque) anyerror!void {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        try self.flush();
        try self.inner.commit();
    }

    fn doRollback(ctx: *anyopaque) anyerror!void {
        const self: *AsyncBatchRepository = @ptrCast(@alignCast(ctx));
        try self.flush();
        try self.inner.rollback();
    }

    const vtable = Repository.VTable{
        .writePayload = &doWritePayload,
        .writePayloadWithParams = &doWritePayloadWithParams,
        .readPayload = &doReadPayload,
        .recordCount = &doRecordCount,
        .deinit = &doDeinit,
        .getCapabilities = &doGetCapabilities,
        .ensureSchema = &doEnsureSchema,
        .write = &doWrite,
        .read = &doRead,
        .readStream = &doReadStream,
        .beginTx = &doBeginTx,
        .commit = &doCommit,
        .rollback = &doRollback,
    };
};
