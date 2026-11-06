const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const PayloadHandle = flowdata.dataflow.PayloadHandle;
const repository = flowdata.repository;
const StorageRepository = repository.StorageRepository;

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
});

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

    pub fn writePayload(self: *FileStoreRepository, channel: []const u8, payload: PayloadHandle) !void {
        var path_buf: [1024]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.bin", .{ self.directory, channel });

        const path_z = try self.allocator.dupeZ(u8, file_path);
        defer self.allocator.free(path_z);

        const fp = c.fopen(path_z.ptr, "wb") orelse return error.FileOpenFailed;
        defer _ = c.fclose(fp);

        if (payload.len > 0) {
            const written = c.fwrite(payload.ptr, 1, payload.len, fp);
            if (written != payload.len) {
                return error.DiskWriteFailed;
            }
        }
        self.file_count += 1;
    }

    pub fn readPayload(self: *const FileStoreRepository, channel: []const u8) ?PayloadHandle {
        _ = self;
        _ = channel;
        return null;
    }

    pub fn recordCount(self: *const FileStoreRepository, channel: []const u8) usize {
        _ = channel;
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

    pub fn createHeap(allocator: Allocator, params: []const repository.ConfigParam) anyerror!StorageRepository {
        var dir: []const u8 = "./artifacts";
        for (params) |p| {
            if (std.mem.eql(u8, p.key, "directory") or std.mem.eql(u8, p.key, "path")) {
                dir = p.value;
            }
        }

        const self_ptr = try allocator.create(FileStoreRepository);
        self_ptr.* = try FileStoreRepository.init(allocator, dir);

        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const s: *FileStoreRepository = @ptrCast(@alignCast(ctx));
                try s.writePayload(channel, payload);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const s: *const FileStoreRepository = @ptrCast(@alignCast(ctx));
                return s.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const s: *const FileStoreRepository = @ptrCast(@alignCast(ctx));
                return s.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const s: *FileStoreRepository = @ptrCast(@alignCast(ctx));
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
