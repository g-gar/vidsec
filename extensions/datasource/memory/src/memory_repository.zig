const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const PayloadHandle = flowdata.dataflow.PayloadHandle;
const repository = flowdata.repository;
const StorageRepository = repository.StorageRepository;
const Mutex = flowdata.concurrency.Mutex;

/// High-performance in-memory repository for zero-copy streaming between pipeline tasks.
/// Stores PayloadHandles by channel name in RAM with O(1) pointer updates.
pub const MemoryRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    allocator: Allocator,
    payloads: std.StringHashMapUnmanaged(PayloadHandle) = .empty,
    mutex: Mutex = .{},

    pub fn init(allocator: Allocator) MemoryRepository {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryRepository) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var iter = self.payloads.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.payloads.deinit(self.allocator);
    }

    pub fn writePayload(self: *MemoryRepository, channel: []const u8, payload: PayloadHandle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.payloads.getPtr(channel)) |existing| {
            existing.* = payload;
            return;
        }
        const owned_channel = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(owned_channel);
        try self.payloads.put(self.allocator, owned_channel, payload);
    }

    pub fn readPayload(self: *const MemoryRepository, channel: []const u8) ?PayloadHandle {
        const mutable = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        return self.payloads.get(channel);
    }

    pub fn recordCount(self: *const MemoryRepository, channel: []const u8) usize {
        const mutable = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        if (self.payloads.get(channel)) |h| return h.len;
        return 0;
    }

    pub fn storageRepository(self: *MemoryRepository) StorageRepository {
        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const self_ptr: *MemoryRepository = @ptrCast(@alignCast(ctx));
                try self_ptr.writePayload(channel, payload);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const self_ptr: *const MemoryRepository = @ptrCast(@alignCast(ctx));
                return self_ptr.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const self_ptr: *const MemoryRepository = @ptrCast(@alignCast(ctx));
                return self_ptr.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const self_ptr: *MemoryRepository = @ptrCast(@alignCast(ctx));
                self_ptr.deinit();
            }

            const vtable = StorageRepository.VTable{
                .writePayload = &doWritePayload,
                .readPayload = &doReadPayload,
                .recordCount = &doRecordCount,
                .deinit = &doDeinit,
            };
        };

        return .{
            .ptr = self,
            .vtable = &Trampoline.vtable,
        };
    }

    pub fn createHeap(allocator: Allocator, params: []const repository.ConfigParam) anyerror!StorageRepository {
        _ = params;
        const self_ptr = try allocator.create(MemoryRepository);
        self_ptr.* = MemoryRepository.init(allocator);

        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const s: *MemoryRepository = @ptrCast(@alignCast(ctx));
                try s.writePayload(channel, payload);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const s: *const MemoryRepository = @ptrCast(@alignCast(ctx));
                return s.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const s: *const MemoryRepository = @ptrCast(@alignCast(ctx));
                return s.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const s: *MemoryRepository = @ptrCast(@alignCast(ctx));
                const alloc = s.allocator;
                s.deinit();
                alloc.destroy(s);
            }

            const vtable = StorageRepository.VTable{
                .writePayload = &doWritePayload,
                .readPayload = &doReadPayload,
                .recordCount = &doRecordCount,
                .deinit = &doDeinit,
            };
        };

        return .{
            .ptr = self_ptr,
            .vtable = &Trampoline.vtable,
        };
    }
};
