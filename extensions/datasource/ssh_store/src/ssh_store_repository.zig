const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const PayloadHandle = flowdata.dataflow.PayloadHandle;
const repository = flowdata.repository;
const StorageRepository = repository.StorageRepository;
const ConfigParam = repository.ConfigParam;

pub const SshConfig = struct {
    host: []const u8 = "",
    port: []const u8 = "22",
    user: []const u8 = "",
    identity_file: []const u8 = "",
    directory: []const u8 = "/tmp",
    strict_host_key_checking: []const u8 = "accept-new",
};

/// Remote SSH/SCP storage repository for uploading in-memory artifacts or local files
/// to a remote host without requiring intermediate local disk files.
pub const SshStoreRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    allocator: Allocator,
    config: SshConfig,
    file_count: usize = 0,

    pub fn init(allocator: Allocator, config: SshConfig) !SshStoreRepository {
        return .{
            .allocator = allocator,
            .config = .{
                .host = try allocator.dupe(u8, config.host),
                .port = try allocator.dupe(u8, config.port),
                .user = try allocator.dupe(u8, config.user),
                .identity_file = try allocator.dupe(u8, config.identity_file),
                .directory = try allocator.dupe(u8, config.directory),
                .strict_host_key_checking = try allocator.dupe(u8, config.strict_host_key_checking),
            },
            .file_count = 0,
        };
    }

    pub fn deinit(self: *SshStoreRepository) void {
        self.allocator.free(self.config.host);
        self.allocator.free(self.config.port);
        self.allocator.free(self.config.user);
        self.allocator.free(self.config.identity_file);
        self.allocator.free(self.config.directory);
        self.allocator.free(self.config.strict_host_key_checking);
    }

    fn getParam(params: []const ConfigParam, key: []const u8) ?[]const u8 {
        for (params) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    fn shellSingleQuote(alloc: Allocator, input: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        try buf.append(alloc, '\'');
        for (input) |ch| {
            if (ch == '\'') {
                try buf.appendSlice(alloc, "'\\''");
            } else {
                try buf.append(alloc, ch);
            }
        }
        try buf.append(alloc, '\'');
        return buf.toOwnedSlice(alloc);
    }

    fn joinRemotePath(alloc: Allocator, base: []const u8, sub: []const u8, filename: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);

        const trimmed_base = std.mem.trimEnd(u8, base, "/");
        if (trimmed_base.len > 0) {
            try buf.appendSlice(alloc, trimmed_base);
        }

        const trimmed_sub = std.mem.trim(u8, sub, "/");
        if (trimmed_sub.len > 0) {
            if (buf.items.len > 0) try buf.append(alloc, '/');
            try buf.appendSlice(alloc, trimmed_sub);
        }

        const trimmed_file = std.mem.trimStart(u8, filename, "/");
        if (trimmed_file.len > 0) {
            if (buf.items.len > 0) try buf.append(alloc, '/');
            try buf.appendSlice(alloc, trimmed_file);
        }

        return buf.toOwnedSlice(alloc);
    }

    pub fn resolveRemotePath(
        self: *const SshStoreRepository,
        alloc: Allocator,
        channel: []const u8,
        payload: PayloadHandle,
        params: []const ConfigParam,
    ) ![]const u8 {
        if (getParam(params, "remote_path")) |rp| {
            if (rp.len > 0) {
                if (rp[0] == '/') return alloc.dupe(u8, rp);
                return joinRemotePath(alloc, self.config.directory, "", rp);
            }
        }

        const remote_dir = getParam(params, "remote_dir") orelse getParam(params, "directory") orelse "";
        const filename = getParam(params, "filename") orelse blk: {
            if (payload.getReflected("filename")) |rv| {
                if (rv.asString()) |s| {
                    if (s.len > 0) break :blk s;
                }
            }
            break :blk null;
        };

        if (filename) |fname| {
            return joinRemotePath(alloc, self.config.directory, remote_dir, fname);
        }

        const fallback = try std.fmt.allocPrint(alloc, "{s}.bin", .{channel});
        defer alloc.free(fallback);
        return joinRemotePath(alloc, self.config.directory, remote_dir, fallback);
    }

    fn extractMemoryBytes(payload: PayloadHandle) ?[]const u8 {
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
        return null;
    }

    fn extractSourcePath(payload: PayloadHandle, params: []const ConfigParam) ?[]const u8 {
        if (getParam(params, "source_path")) |sp| {
            if (sp.len > 0) return sp;
        }
        const candidate_fields = [_][]const u8{ "archive_path", "file_path", "source_path" };
        for (candidate_fields) |field| {
            if (payload.getReflected(field)) |rv| {
                if (rv.asString()) |s| {
                    if (s.len > 0) return s;
                }
            }
        }
        return null;
    }

    fn buildTarget(self: *const SshStoreRepository, alloc: Allocator) ![]const u8 {
        if (self.config.user.len > 0) {
            return std.fmt.allocPrint(alloc, "{s}@{s}", .{ self.config.user, self.config.host });
        }
        return alloc.dupe(u8, self.config.host);
    }

    fn appendSshCommonArgs(
        self: *const SshStoreRepository,
        alloc: Allocator,
        argv: *std.ArrayListUnmanaged([]const u8),
        port_flag: []const u8,
    ) !void {
        try argv.append(alloc, "-o");
        try argv.append(alloc, "BatchMode=yes");
        if (self.config.strict_host_key_checking.len > 0) {
            try argv.append(alloc, "-o");
            const opt = try std.fmt.allocPrint(alloc, "StrictHostKeyChecking={s}", .{self.config.strict_host_key_checking});
            try argv.append(alloc, opt);
        }
        if (self.config.port.len > 0 and !std.mem.eql(u8, self.config.port, "22")) {
            try argv.append(alloc, port_flag);
            try argv.append(alloc, self.config.port);
        }
        if (self.config.identity_file.len > 0) {
            try argv.append(alloc, "-i");
            try argv.append(alloc, self.config.identity_file);
        }
    }

    fn runSshCommand(self: *const SshStoreRepository, remote_cmd: []const u8, stdin_bytes: ?[]const u8) !void {
        var arena_impl = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_impl.deinit();
        const arena = arena_impl.allocator();

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(arena, "ssh");
        try self.appendSshCommonArgs(arena, &argv, "-p");
        const target = try self.buildTarget(arena);
        try argv.append(arena, target);
        try argv.append(arena, remote_cmd);

        var threaded = std.Io.Threaded.init(arena, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = if (stdin_bytes != null) .pipe else .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        });

        if (stdin_bytes) |bytes| {
            if (child.stdin) |*stdin_file| {
                try stdin_file.writeStreamingAll(io, bytes);
                stdin_file.close(io);
                child.stdin = null;
            }
        }

        const term = try child.wait(io);
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    std.log.err("[ssh_store] ssh command exited with code {d}: {s}", .{ code, remote_cmd });
                    return error.SshCommandFailed;
                }
            },
            else => return error.SshCommandFailed,
        }
    }

    fn runScpUpload(self: *const SshStoreRepository, local_path: []const u8, remote_path: []const u8) !void {
        var arena_impl = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_impl.deinit();
        const arena = arena_impl.allocator();

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(arena, "scp");
        try self.appendSshCommonArgs(arena, &argv, "-P");
        const target = try self.buildTarget(arena);
        const dest = try std.fmt.allocPrint(arena, "{s}:{s}", .{ target, remote_path });
        try argv.append(arena, local_path);
        try argv.append(arena, dest);

        var threaded = std.Io.Threaded.init(arena, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        });

        const term = try child.wait(io);
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    std.log.err("[ssh_store] scp upload exited with code {d}: {s} -> {s}", .{ code, local_path, remote_path });
                    return error.ScpUploadFailed;
                }
            },
            else => return error.ScpUploadFailed,
        }
    }

    pub fn writePayload(self: *SshStoreRepository, channel: []const u8, payload: PayloadHandle) !void {
        try self.writePayloadWithParams(channel, payload, &.{});
    }

    pub fn writePayloadWithParams(
        self: *SshStoreRepository,
        channel: []const u8,
        payload: PayloadHandle,
        params: []const ConfigParam,
    ) !void {
        if (self.config.host.len == 0) return error.MissingSshHost;

        const remote_path = try self.resolveRemotePath(self.allocator, channel, payload, params);
        defer self.allocator.free(remote_path);

        if (std.mem.lastIndexOfScalar(u8, remote_path, '/')) |slash_idx| {
            if (slash_idx > 0) {
                const parent_dir = remote_path[0..slash_idx];
                const quoted_parent = try shellSingleQuote(self.allocator, parent_dir);
                defer self.allocator.free(quoted_parent);
                const mkdir_cmd = try std.fmt.allocPrint(self.allocator, "mkdir -p {s}", .{quoted_parent});
                defer self.allocator.free(mkdir_cmd);
                try self.runSshCommand(mkdir_cmd, null);
            }
        }

        if (extractMemoryBytes(payload)) |bytes| {
            const quoted_remote = try shellSingleQuote(self.allocator, remote_path);
            defer self.allocator.free(quoted_remote);
            const cat_cmd = try std.fmt.allocPrint(self.allocator, "cat > {s}", .{quoted_remote});
            defer self.allocator.free(cat_cmd);
            try self.runSshCommand(cat_cmd, bytes);
            self.file_count += 1;
            return;
        }

        if (extractSourcePath(payload, params)) |local_path| {
            try self.runScpUpload(local_path, remote_path);
            self.file_count += 1;
            return;
        }

        return error.MissingUploadPayload;
    }

    pub fn readPayload(_: *const SshStoreRepository, _: []const u8) ?PayloadHandle {
        return null;
    }

    pub fn recordCount(self: *const SshStoreRepository, _: []const u8) usize {
        return self.file_count;
    }

    pub fn storageRepository(self: *SshStoreRepository) StorageRepository {
        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const s: *SshStoreRepository = @ptrCast(@alignCast(ctx));
                try s.writePayload(channel, payload);
            }

            fn doWritePayloadWithParams(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle, params: []const ConfigParam) anyerror!void {
                const s: *SshStoreRepository = @ptrCast(@alignCast(ctx));
                try s.writePayloadWithParams(channel, payload, params);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const s: *const SshStoreRepository = @ptrCast(@alignCast(ctx));
                return s.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const s: *const SshStoreRepository = @ptrCast(@alignCast(ctx));
                return s.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const s: *SshStoreRepository = @ptrCast(@alignCast(ctx));
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
            .ptr = self,
            .vtable = &Trampoline.vtable,
        };
    }

    pub fn createHeap(allocator: Allocator, params: []const ConfigParam) anyerror!StorageRepository {
        var cfg = SshConfig{};
        for (params) |p| {
            if (std.mem.eql(u8, p.key, "host")) {
                cfg.host = p.value;
            } else if (std.mem.eql(u8, p.key, "port")) {
                cfg.port = p.value;
            } else if (std.mem.eql(u8, p.key, "user")) {
                cfg.user = p.value;
            } else if (std.mem.eql(u8, p.key, "identity_file") or std.mem.eql(u8, p.key, "key_path")) {
                cfg.identity_file = p.value;
            } else if (std.mem.eql(u8, p.key, "directory") or std.mem.eql(u8, p.key, "path")) {
                cfg.directory = p.value;
            } else if (std.mem.eql(u8, p.key, "strict_host_key_checking")) {
                cfg.strict_host_key_checking = p.value;
            }
        }

        const self_ptr = try allocator.create(SshStoreRepository);
        errdefer allocator.destroy(self_ptr);
        self_ptr.* = try SshStoreRepository.init(allocator, cfg);
        return self_ptr.storageRepository();
    }
};

