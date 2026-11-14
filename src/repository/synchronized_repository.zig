const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const Mutex = @import("../concurrency/mod.zig").Mutex;
const storage = @import("storage_repository.zig");
const Repository = storage.Repository;
const ConfigParam = storage.ConfigParam;
const specs = @import("specs.zig");
const capabilities_mod = @import("capabilities.zig");
const RowIterator = @import("row_iterator.zig").RowIterator;

/// `SynchronizedRepository` — Concurrency Decorator (ARCH-009A §2.5)
///
/// Wraps any `Repository` with a `std.Thread.Mutex`, serializing all vtable calls
/// from concurrent callers. The underlying driver remains completely thread-agnostic
/// (single-responsibility; zero mutex code inside drivers themselves).
///
/// Applied automatically by the engine when `scheduler: dag` is active so that
/// parallel DAG workers can safely share repositories without file-level contention
/// or deadlocks.
///
/// Concurrency policy note: this decorator serializes ALL operations (reads and writes)
/// behind a single mutex — safe and simple for single-connection drivers (including
/// SQLite WAL). If read contention becomes a bottleneck under WAL, introduce a
/// dedicated read-only connection pool wrapper rather than nesting multiple mutexes.
///
/// Usage:
/// ```zig
/// var synced = SynchronizedRepository.init(allocator, inner_repo);
/// defer synced.deinit();
/// const repo = synced.repository();
/// ```
pub const SynchronizedRepository = struct {
    inner: Repository,
    mutex: Mutex = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator, inner: Repository) SynchronizedRepository {
        return .{
            .inner = inner,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SynchronizedRepository) void {
        self.inner.deinit();
    }

    pub fn repository(self: *SynchronizedRepository) Repository {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // ── Trampoline implementations ────────────────────────────────────────────

    fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.inner.writePayload(channel, payload);
    }

    fn doWritePayloadWithParams(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle, params: []const ConfigParam) anyerror!void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.inner.writePayloadWithParams(channel, payload, params);
    }

    fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.inner.readPayload(channel);
    }

    fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.inner.recordCount(channel);
    }

    fn doDeinit(ctx: *anyopaque) void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn doGetCapabilities(ctx: *const anyopaque) capabilities_mod.Capabilities {
        const self: *const SynchronizedRepository = @ptrCast(@alignCast(ctx));
        return self.inner.getCapabilities();
    }

    fn doEnsureSchema(ctx: *anyopaque, catalog: *const anyopaque) anyerror!void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.inner.ensureSchema(catalog);
    }

    fn doWrite(ctx: *anyopaque, ws: specs.WriteSpec) anyerror!void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.inner.write(ws);
    }

    fn doRead(ctx: *anyopaque, allocator: Allocator, rs: specs.ReadSpec) anyerror!PayloadHandle {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.inner.read(allocator, rs);
    }

    fn doReadStream(ctx: *anyopaque, allocator: Allocator, rs: specs.ReadSpec) anyerror!RowIterator {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        // NOTE: We only lock during the stream *open*. The RowIterator's `next()` calls
        // must be driven from a single goroutine; concurrent `next()` calls on the same
        // iterator are not supported by any driver (use separate ReadSpec calls instead).
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.inner.readStream(allocator, rs);
    }

    fn doBeginTx(ctx: *anyopaque) anyerror!void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.inner.beginTx();
    }

    fn doCommit(ctx: *anyopaque) anyerror!void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.inner.commit();
    }

    fn doRollback(ctx: *anyopaque) anyerror!void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.inner.rollback();
    }

    fn doBeginSavepoint(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.inner.beginSavepoint(name);
    }

    fn doRollbackSavepoint(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.inner.rollbackSavepoint(name);
    }

    fn doReleaseSavepoint(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *SynchronizedRepository = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.inner.releaseSavepoint(name);
    }

    const vtable = Repository.VTable{
        .writePayload = doWritePayload,
        .writePayloadWithParams = doWritePayloadWithParams,
        .readPayload = doReadPayload,
        .recordCount = doRecordCount,
        .deinit = doDeinit,
        .getCapabilities = doGetCapabilities,
        .ensureSchema = doEnsureSchema,
        .write = doWrite,
        .read = doRead,
        .readStream = doReadStream,
        .beginTx = doBeginTx,
        .commit = doCommit,
        .rollback = doRollback,
        .beginSavepoint = doBeginSavepoint,
        .rollbackSavepoint = doRollbackSavepoint,
        .releaseSavepoint = doReleaseSavepoint,
    };
};

