const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite_core = @import("../../sqlite/mod.zig");
const NamedValue = sqlite_core.NamedValue;
const Value = sqlite_core.Value;

/// Abstract interface for storage repositories (Memory, SQLite, DuckDB, Parquet, etc.).
pub const StorageRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        saveRecord: *const fn (ctx: *anyopaque, table_name: []const u8, fields: []const NamedValue) anyerror!void,
        recordCount: *const fn (ctx: *anyopaque, table_name: []const u8) usize,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn saveRecord(self: StorageRepository, table_name: []const u8, fields: []const NamedValue) !void {
        try self.vtable.saveRecord(self.ptr, table_name, fields);
    }

    pub fn recordCount(self: StorageRepository, table_name: []const u8) usize {
        return self.vtable.recordCount(self.ptr, table_name);
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
