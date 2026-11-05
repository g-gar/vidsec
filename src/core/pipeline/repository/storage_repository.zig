const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("vidsec_dataflow");
const PayloadHandle = dataflow.PayloadHandle;

/// Polymorphic abstract interface for storage repositories (Memory, SQLite, FileStore, Elasticsearch, etc.).
/// Completely decoupled from SQL and underlying storage engines.
pub const StorageRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writePayload: *const fn (ctx: *anyopaque, channel_or_table: []const u8, payload: PayloadHandle) anyerror!void,
        readPayload: *const fn (ctx: *anyopaque, channel_or_table: []const u8) ?PayloadHandle,
        recordCount: *const fn (ctx: *anyopaque, channel_or_table: []const u8) usize,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn writePayload(self: StorageRepository, channel_or_table: []const u8, payload: PayloadHandle) !void {
        try self.vtable.writePayload(self.ptr, channel_or_table, payload);
    }

    pub fn readPayload(self: StorageRepository, channel_or_table: []const u8) ?PayloadHandle {
        return self.vtable.readPayload(self.ptr, channel_or_table);
    }

    pub fn recordCount(self: StorageRepository, channel_or_table: []const u8) usize {
        return self.vtable.recordCount(self.ptr, channel_or_table);
    }

    pub fn deinit(self: StorageRepository) void {
        self.vtable.deinit(self.ptr);
    }

    /// Statically asserts at compile-time that type `T` strictly implements the `StorageRepository` interface.
    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "storageRepository")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn storageRepository(*" ++ @typeName(T) ++ ") StorageRepository'");
            }
        }
    }
};
