const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("vidsec_abi");
const RowView_ABI = abi.RowView_ABI;
const WindowView_ABI = abi.WindowView_ABI;
const MemoryCursor = @import("memory_cursor.zig").MemoryCursor;
const QueryCursor = @import("query_cursor.zig").QueryCursor;

/// Unified record and window cursor for pipeline execution.
/// Seamlessly abstracts over in-memory streams and persistent database queries.
pub const RecordCursor = union(enum) {
    memory: MemoryCursor,
    sqlite: QueryCursor,

    pub fn deinit(self: *RecordCursor, allocator: Allocator) void {
        switch (self.*) {
            .memory => |*m| m.deinit(allocator),
            .sqlite => |*s| s.deinit(allocator),
        }
    }

    pub fn streamSource(self: *const RecordCursor) ?[]const u8 {
        return switch (self.*) {
            .memory => |*m| m.stream_source,
            .sqlite => |*s| s.stream_source,
        };
    }

    pub fn nextRow(self: *RecordCursor, allocator: Allocator) !?RowView_ABI {
        return switch (self.*) {
            .memory => |*m| try m.nextRow(allocator),
            .sqlite => |*s| try s.nextRow(),
        };
    }

    pub fn nextWindow(self: *RecordCursor) !?WindowView_ABI {
        return switch (self.*) {
            .memory => |*m| try m.nextWindow(),
            .sqlite => |*s| try s.nextWindow(),
        };
    }
};
