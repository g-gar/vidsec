const std = @import("std");
const Allocator = std.mem.Allocator;
const repository_mod = @import("../../repository/mod.zig");
const StorageRepository = repository_mod.StorageRepository;
const strategy_mod = @import("strategy.zig");
const BatchSource = strategy_mod.BatchSource;
const RecordEmitter = strategy_mod.RecordEmitter;

/// BatchSource implementation that reads from a `StorageRepository` (typically `role: source`)
/// and emits each element individually if the payload is a typed/dynamic slice, or as a single item.
pub const DatasourceSliceSource = struct {
    comptime {
        BatchSource.assertImplements(@This());
    }

    allocator: Allocator,
    source_id: []const u8,
    repo: StorageRepository,
    channel_or_table: []const u8,
    owns_self: bool = false,

    pub fn init(
        allocator: Allocator,
        source_id: []const u8,
        repo: StorageRepository,
        channel_or_table: []const u8,
    ) DatasourceSliceSource {
        return .{
            .allocator = allocator,
            .source_id = source_id,
            .repo = repo,
            .channel_or_table = channel_or_table,
            .owns_self = false,
        };
    }

    pub fn createHeap(
        allocator: Allocator,
        source_id: []const u8,
        repo: StorageRepository,
        channel_or_table: []const u8,
    ) !*DatasourceSliceSource {
        const self = try allocator.create(DatasourceSliceSource);
        self.* = .{
            .allocator = allocator,
            .source_id = source_id,
            .repo = repo,
            .channel_or_table = channel_or_table,
            .owns_self = true,
        };
        return self;
    }

    pub fn deinit(self: *DatasourceSliceSource) void {
        if (self.owns_self) {
            self.allocator.destroy(self);
        }
    }

    pub fn batchSource(self: *DatasourceSliceSource) BatchSource {
        return BatchSource.fromImpl(DatasourceSliceSource, self);
    }

    pub fn emitAll(self: *DatasourceSliceSource, _: Allocator, emitter: RecordEmitter) anyerror!usize {
        const payload = self.repo.readPayload(self.channel_or_table) orelse return 0;

        if (payload.is_stream and payload.repr != .bytes and payload.element_size > 0) {
            var emitted: usize = 0;
            var i: usize = 0;
            while (i < payload.len) : (i += 1) {
                if (payload.elementAt(i)) |elem| {
                    try emitter.emit(self.source_id, elem);
                    emitted += 1;
                }
            }
            return emitted;
        }

        if (payload.len == 0) return 0;
        try emitter.emit(self.source_id, payload);
        return 1;
    }
};
