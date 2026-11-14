const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("storage_repository.zig");
const Repository = storage.Repository;
const SynchronizedRepository = @import("synchronized_repository.zig").SynchronizedRepository;
const AsyncBatchRepository = @import("async_batch_repository.zig").AsyncBatchRepository;

/// Explicit concurrency policy selected when instantiating/wrapping a `Repository`.
/// Forces callers (engine, tests, apps) to declare how concurrent access is handled
/// rather than relying on implicit locks inside storage drivers.
pub const ConcurrencyPolicy = union(enum) {
    /// Single-threaded / external synchronization; `inner` is used directly with zero overhead.
    none,
    /// Serializes all repository operations behind a single `Mutex`.
    /// Safe default for single-connection drivers (including SQLite WAL).
    mutex,
    /// Bounded MPSC write queue + dedicated background writer thread flushing in transactions.
    /// Reads automatically flush pending writes for read-your-own-writes consistency.
    async_batch: AsyncBatchRepository.Options,
};

/// Owns a `Repository` wrapped according to a chosen `ConcurrencyPolicy`,
/// providing a uniform `.repository()` and `.deinit()` lifecycle.
pub const ManagedRepository = union(enum) {
    none: Repository,
    mutex: struct {
        allocator: Allocator,
        wrapper: *SynchronizedRepository,
    },
    async_batch: struct {
        allocator: Allocator,
        wrapper: *AsyncBatchRepository,
    },

    pub fn init(allocator: Allocator, inner: Repository, policy: ConcurrencyPolicy) !ManagedRepository {
        switch (policy) {
            .none => return .{ .none = inner },
            .mutex => {
                const wrapper = try allocator.create(SynchronizedRepository);
                wrapper.* = SynchronizedRepository.init(allocator, inner);
                return .{ .mutex = .{
                    .allocator = allocator,
                    .wrapper = wrapper,
                } };
            },
            .async_batch => |opts| {
                const wrapper = try allocator.create(AsyncBatchRepository);
                wrapper.* = AsyncBatchRepository.init(allocator, inner, opts);
                return .{ .async_batch = .{
                    .allocator = allocator,
                    .wrapper = wrapper,
                } };
            },
        }
    }

    pub fn repository(self: *ManagedRepository) Repository {
        return switch (self.*) {
            .none => |r| r,
            .mutex => |m| m.wrapper.repository(),
            .async_batch => |a| a.wrapper.repository(),
        };
    }

    pub fn deinit(self: *ManagedRepository) void {
        switch (self.*) {
            .none => |r| r.deinit(),
            .mutex => |m| {
                m.wrapper.deinit();
                m.allocator.destroy(m.wrapper);
            },
            .async_batch => |a| {
                a.wrapper.deinit();
                a.allocator.destroy(a.wrapper);
            },
        }
    }
};

