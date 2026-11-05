const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("vidsec_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const StorageRepository = @import("storage_repository.zig").StorageRepository;

/// High-performance in-memory repository for zero-copy streaming between pipeline tasks.
/// Stores PayloadHandles by channel name in RAM with O(1) pointer updates.
pub const MemoryRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    allocator: Allocator,
    payloads: std.StringHashMapUnmanaged(PayloadHandle) = .empty,

    pub fn init(allocator: Allocator) MemoryRepository {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryRepository) void {
        var iter = self.payloads.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.payloads.deinit(self.allocator);
    }

    pub fn writePayload(self: *MemoryRepository, channel: []const u8, payload: PayloadHandle) !void {
        if (self.payloads.getPtr(channel)) |existing| {
            existing.* = payload;
            return;
        }
        const owned_channel = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(owned_channel);
        try self.payloads.put(self.allocator, owned_channel, payload);
    }

    pub fn readPayload(self: *const MemoryRepository, channel: []const u8) ?PayloadHandle {
        return self.payloads.get(channel);
    }

    pub fn recordCount(self: *const MemoryRepository, channel: []const u8) usize {
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
};
