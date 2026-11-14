const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const PayloadHandle = flowdata.dataflow.PayloadHandle;
const repository = flowdata.repository;
const StorageRepository = repository.StorageRepository;
const ConfigParam = repository.ConfigParam;

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

    fn ensureParentDirs(alloc: Allocator, path: []const u8) void {
        const slash_idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
        if (slash_idx == 0) return;
        const parent = path[0..slash_idx];

        var it = std.mem.splitScalar(u8, parent, '/');
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);

        if (parent[0] == '/') {
            buf.append(alloc, '/') catch return;
        }

        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
                if (seg.len > 0) {
                    buf.appendSlice(alloc, seg) catch return;
                    buf.append(alloc, '/') catch return;
                }
                continue;
            }
            buf.appendSlice(alloc, seg) catch return;
            if (alloc.dupeZ(u8, buf.items)) |dir_z| {
                defer alloc.free(dir_z);
                _ = c.mkdir(dir_z.ptr, 0o755);
            } else |_| return;
            buf.append(alloc, '/') catch return;
        }
    }

    fn getParam(params: []const ConfigParam, key: []const u8) ?[]const u8 {
        for (params) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    fn extractBytes(payload: PayloadHandle) []const u8 {
        if (payload.repr == .bytes and payload.len > 0) {
            const ptr: [*]const u8 = @ptrCast(payload.ptr);
            return ptr[0..payload.len];
        }
        const candidate_fields = [_][]const u8{ "data", "bytes", "content" };
        for (candidate_fields) |field| {
            if (payload.getReflected(field)) |rv| {
                if (rv.asString()) |s| {
                    if (s.len > 0) return s;
                }
            }
        }
        if (payload.len > 0 and payload.repr == .bytes) {
            const ptr: [*]const u8 = @ptrCast(payload.ptr);
            return ptr[0..payload.len];
        }
        return "";
    }

    pub fn writePayload(self: *FileStoreRepository, channel: []const u8, payload: PayloadHandle) !void {
        var path_buf: [1024]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.bin", .{ self.directory, channel });

        ensureParentDirs(self.allocator, file_path);

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

    pub fn writePayloadWithParams(
        self: *FileStoreRepository,
        channel: []const u8,
        payload: PayloadHandle,
        params: []const ConfigParam,
    ) !void {
        if (params.len == 0) {
            try self.writePayload(channel, payload);
            return;
        }

        const sub_dir = std.mem.trim(u8, getParam(params, "remote_dir") orelse getParam(params, "directory") orelse "", "/");
        const filename = getParam(params, "filename") orelse blk: {
            if (payload.getReflected("filename")) |rv| {
                if (rv.asString()) |s| {
                    if (s.len > 0) break :blk s;
                }
            }
            break :blk null;
        };

        const base = std.mem.trimEnd(u8, self.directory, "/");
        const file_path = if (filename) |fname| blk: {
            if (sub_dir.len > 0) {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ base, sub_dir, fname });
            } else {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, fname });
            }
        } else blk: {
            if (sub_dir.len > 0) {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}.bin", .{ base, sub_dir, channel });
            } else {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}.bin", .{ base, channel });
            }
        };
        defer self.allocator.free(file_path);

        ensureParentDirs(self.allocator, file_path);

        const path_z = try self.allocator.dupeZ(u8, file_path);
        defer self.allocator.free(path_z);

        const fp = c.fopen(path_z.ptr, "wb") orelse return error.FileOpenFailed;
        defer _ = c.fclose(fp);

        const bytes = extractBytes(payload);
        if (bytes.len > 0) {
            const written = c.fwrite(bytes.ptr, 1, bytes.len, fp);
            if (written != bytes.len) {
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

            fn doWritePayloadWithParams(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle, params: []const ConfigParam) anyerror!void {
                const self_ptr: *FileStoreRepository = @ptrCast(@alignCast(ctx));
                try self_ptr.writePayloadWithParams(channel, payload, params);
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
                .writePayloadWithParams = &doWritePayloadWithParams,
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

            fn doWritePayloadWithParams(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle, write_params: []const ConfigParam) anyerror!void {
                const s: *FileStoreRepository = @ptrCast(@alignCast(ctx));
                try s.writePayloadWithParams(channel, payload, write_params);
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
                .writePayloadWithParams = &doWritePayloadWithParams,
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
