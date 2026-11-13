const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;

/// Generic key-value configuration parameter for initializing or writing to storage datasources.
pub const ConfigParam = struct {
    key: []const u8,
    value: []const u8,
};

/// Polymorphic abstract interface for repositories (Memory, SQLite, FileStore, S3, etc.).
/// Completely decoupled from SQL and underlying storage engines (Spring Data / DDD pattern).
pub const Repository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writePayload: *const fn (ctx: *anyopaque, channel_or_table: []const u8, payload: PayloadHandle) anyerror!void,
        readPayload: *const fn (ctx: *anyopaque, channel_or_table: []const u8) ?PayloadHandle,
        recordCount: *const fn (ctx: *anyopaque, channel_or_table: []const u8) usize,
        deinit: *const fn (ctx: *anyopaque) void,
        writePayloadWithParams: ?*const fn (ctx: *anyopaque, channel_or_table: []const u8, payload: PayloadHandle, params: []const ConfigParam) anyerror!void = null,
    };

    pub const RepositoryVTable = VTable;
    pub const StorageRepositoryVTable = VTable;

    pub fn writePayload(self: Repository, channel_or_table: []const u8, payload: PayloadHandle) !void {
        try self.vtable.writePayload(self.ptr, channel_or_table, payload);
    }

    pub fn writePayloadWithParams(
        self: Repository,
        channel_or_table: []const u8,
        payload: PayloadHandle,
        params: []const ConfigParam,
    ) !void {
        if (self.vtable.writePayloadWithParams) |write_fn| {
            try write_fn(self.ptr, channel_or_table, payload, params);
        } else {
            try self.vtable.writePayload(self.ptr, channel_or_table, payload);
        }
    }

    pub fn readPayload(self: Repository, channel_or_table: []const u8) ?PayloadHandle {
        return self.vtable.readPayload(self.ptr, channel_or_table);
    }

    pub fn recordCount(self: Repository, channel_or_table: []const u8) usize {
        return self.vtable.recordCount(self.ptr, channel_or_table);
    }

    pub fn deinit(self: Repository) void {
        self.vtable.deinit(self.ptr);
    }

    /// Statically asserts at compile-time that type `T` strictly implements the `Repository` interface.
    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "repository") and !@hasDecl(T, "storageRepository")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn repository(*" ++ @typeName(T) ++ ") Repository' or 'pub fn storageRepository(*" ++ @typeName(T) ++ ") StorageRepository'");
            }
        }
    }
};

pub const StorageRepository = Repository;
