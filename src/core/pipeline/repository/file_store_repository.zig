const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("vidsec_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const StorageRepository = @import("storage_repository.zig").StorageRepository;

/// Physical disk directory repository for carved payloads, quarantined samples, and exported artifacts.
pub const FileStoreRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    allocator: Allocator,
    directory: []const u8,
    file_count: usize = 0,

    pub fn init(allocator: Allocator, directory: []const u8) !FileStoreRepository {
        const owned_dir = try allocator.dupe(u8, directory);
        return .{
            .allocator = allocator,
            .directory = owned_dir,
            .file_count = 0,
        };
    }

    pub fn deinit(self: *FileStoreRepository) void {
        self.allocator.free(self.directory);
    }

    pub fn writePayload(self: *FileStoreRepository, file_name: []const u8, payload: PayloadHandle) !void {
        // Ensure directory exists
        std.fs.cwd().makePath(self.directory) catch {};

        const full_path = try std.fs.path.join(self.allocator, &.{ self.directory, file_name });
        defer self.allocator.free(full_path);

        const file = try std.fs.cwd().createFile(full_path, .{});
        defer file.close();

        const total_bytes = if (payload.is_stream) payload.len * payload.element_size else payload.element_size;
        if (total_bytes > 0) {
            const bytes: [*]const u8 = @ptrCast(payload.ptr);
            try file.writeAll(bytes[0..total_bytes]);
        }
        self.file_count += 1;
    }

    pub fn readPayload(self: *const FileStoreRepository, file_name: []const u8) ?PayloadHandle {
        _ = self;
        _ = file_name;
        return null;
    }

    pub fn recordCount(self: *const FileStoreRepository, _: []const u8) usize {
        return self.file_count;
    }

    pub fn storageRepository(self: *FileStoreRepository) StorageRepository {
        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const self_ptr: *FileStoreRepository = @ptrCast(@alignCast(ctx));
                try self_ptr.writePayload(channel, payload);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const self_ptr: *const FileStoreRepository = @ptrCast(@alignCast(ctx));
                return self_ptr.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const self_ptr: *const FileStoreRepository = @ptrCast(@alignCast(ctx));
                return self_ptr.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const self_ptr: *FileStoreRepository = @ptrCast(@alignCast(ctx));
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
