const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const PayloadHandle = flowdata.dataflow.PayloadHandle;
const repository = flowdata.repository;
const StorageRepository = repository.StorageRepository;
const JobSpec = flowdata.ast.JobSpec;
const yaml = flowdata.yaml;

/// File-based YAML datasource driver.
/// Parses an external YAML file containing jobs or target entries and exposes them
/// as a stream of `JobSpec` records for declarative pipeline tasks.
pub const YamlFileRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    arena: std.heap.ArenaAllocator,
    file_path: []const u8,
    jobs: []const JobSpec,

    pub fn init(allocator: Allocator, path: []const u8) !YamlFileRepository {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const owned_path = try arena_alloc.dupe(u8, path);

        const yaml_bytes = try flowdata.readFileBytes(arena_alloc, path);

        var env_interp = yaml.EnvInterpolator.init(false);
        const root_node = try yaml.yaml_lib.parseAst(arena_alloc, yaml_bytes, .{
            .scalar_hook = env_interp.scalarHook(),
        });

        var jobs_list: std.ArrayListUnmanaged(JobSpec) = .empty;

        if (root_node.asSeq()) |seq| {
            for (seq, 0..) |item, idx| {
                const job = try yaml.parseJobEntry(arena_alloc, item, idx);
                if (job.enabled) {
                    try jobs_list.append(arena_alloc, job);
                }
            }
        } else if (root_node.asMap()) |_| {
            const j_node = root_node.get("jobs") orelse root_node.get("targets") orelse root_node.get("items");
            if (j_node) |jn| {
                if (jn.asSeq()) |seq| {
                    for (seq, 0..) |item, idx| {
                        const job = try yaml.parseJobEntry(arena_alloc, item, idx);
                        if (job.enabled) {
                            try jobs_list.append(arena_alloc, job);
                        }
                    }
                }
            }
        }

        return .{
            .arena = arena,
            .file_path = owned_path,
            .jobs = try jobs_list.toOwnedSlice(arena_alloc),
        };
    }

    pub fn deinit(self: *YamlFileRepository) void {
        self.arena.deinit();
    }

    pub fn writePayload(_: *YamlFileRepository, _: []const u8, _: PayloadHandle) anyerror!void {
        return error.ReadOnlyDatasource;
    }

    pub fn readPayload(self: *const YamlFileRepository, _: []const u8) ?PayloadHandle {
        if (self.jobs.len == 0) return null;
        return PayloadHandle.fromSlice(JobSpec, self.jobs);
    }

    pub fn recordCount(self: *const YamlFileRepository, _: []const u8) usize {
        return self.jobs.len;
    }

    pub fn storageRepository(self: *YamlFileRepository) StorageRepository {
        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const s: *YamlFileRepository = @ptrCast(@alignCast(ctx));
                try s.writePayload(channel, payload);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const s: *const YamlFileRepository = @ptrCast(@alignCast(ctx));
                return s.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const s: *const YamlFileRepository = @ptrCast(@alignCast(ctx));
                return s.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const s: *YamlFileRepository = @ptrCast(@alignCast(ctx));
                s.deinit();
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
        var path_opt: ?[]const u8 = null;
        for (params) |p| {
            if (std.mem.eql(u8, p.key, "path") or std.mem.eql(u8, p.key, "file")) {
                path_opt = p.value;
            }
        }

        const file_path = path_opt orelse return error.MissingPathParameter;

        const self_ptr = try allocator.create(YamlFileRepository);
        self_ptr.* = try YamlFileRepository.init(allocator, file_path);

        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const s: *YamlFileRepository = @ptrCast(@alignCast(ctx));
                try s.writePayload(channel, payload);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const s: *const YamlFileRepository = @ptrCast(@alignCast(ctx));
                return s.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const s: *const YamlFileRepository = @ptrCast(@alignCast(ctx));
                return s.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const s: *YamlFileRepository = @ptrCast(@alignCast(ctx));
                const backing_alloc = s.arena.child_allocator;
                s.deinit();
                backing_alloc.destroy(s);
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
