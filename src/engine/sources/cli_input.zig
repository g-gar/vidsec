const std = @import("std");
const Allocator = std.mem.Allocator;
const strategy_mod = @import("strategy.zig");
const BatchSource = strategy_mod.BatchSource;
const RecordEmitter = strategy_mod.RecordEmitter;
const PayloadHandle = strategy_mod.PayloadHandle;

/// BatchSource implementation wrapping a single in-memory CLI/file payload.
pub const CliInputSource = struct {
    comptime {
        BatchSource.assertImplements(@This());
    }

    allocator: Allocator,
    source_id: []const u8,
    payload: PayloadHandle,
    owns_self: bool = false,

    pub fn init(allocator: Allocator, source_id: []const u8, payload: PayloadHandle) CliInputSource {
        return .{
            .allocator = allocator,
            .source_id = source_id,
            .payload = payload,
            .owns_self = false,
        };
    }

    pub fn deinit(self: *CliInputSource) void {
        if (self.owns_self) {
            self.allocator.destroy(self);
        }
    }

    pub fn batchSource(self: *CliInputSource) BatchSource {
        return BatchSource.fromImpl(CliInputSource, self);
    }

    pub fn emitAll(self: *CliInputSource, _: Allocator, emitter: RecordEmitter) anyerror!usize {
        if (self.payload.len == 0) return 0;
        try emitter.emit(self.source_id, self.payload);
        return 1;
    }
};
