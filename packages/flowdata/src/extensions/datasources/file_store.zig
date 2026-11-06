const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("../../dataflow/mod.zig");
const PayloadHandle = dataflow.PayloadHandle;
const StorageRepository = @import("../../repository/storage_repository.zig").StorageRepository;

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

    pub fn writePayload(self: *FileStoreRepository, file_name: []const u8, payload: PayloadHandle) !void {
        // Ensure directory exists
        const dir_z = try self.allocator.dupeZ(u8, self.directory);
        defer self.allocator.free(dir_z);
        _ = c.mkdir(dir_z.ptr, 0o755);

        const full_path_slice = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.directory, file_name });
        defer self.allocator.free(full_path_slice);
        const full_path = try self.allocator.dupeZ(u8, full_path_slice);
        defer self.allocator.free(full_path);

        const fp = c.fopen(full_path.ptr, "wb") orelse return error.FileOpenFailed;
        defer _ = c.fclose(fp);

        const total_bytes = if (payload.is_stream) payload.len * payload.element_size else payload.element_size;
        if (total_bytes > 0) {
            const written = c.fwrite(payload.ptr, 1, total_bytes, fp);
            if (written != total_bytes) return error.FileWriteFailed;
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

    pub fn createHeap(allocator: Allocator, params: []const @import("../../ast/ast.zig").KeyValueParam) anyerror!StorageRepository {
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
