const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const specs = @import("specs.zig");
const capabilities = @import("capabilities.zig");

/// Generic key-value configuration parameter for initializing or writing to storage datasources.
pub const ConfigParam = struct {
    key: []const u8,
    value: []const u8,
};

/// Polymorphic abstract interface for repositories (Memory, SQLite, FileStore, S3, etc.).
/// Completely decoupled from SQL and underlying storage engines (Spring Data / DDD pattern).
///
/// Drivers implement the mandatory vtable slots (`writePayload`, `readPayload`, `recordCount`, `deinit`)
/// for backward compatibility. All 009A extensions (`capabilities`, `write`, `readStream`, etc.)
/// are optional (`null`) and must be checked before dispatch.
pub const Repository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // ── Legacy mandatory slots (all existing drivers implement these) ──────────
        writePayload: *const fn (ctx: *anyopaque, channel_or_table: []const u8, payload: PayloadHandle) anyerror!void,
        readPayload: *const fn (ctx: *anyopaque, channel_or_table: []const u8) ?PayloadHandle,
        recordCount: *const fn (ctx: *anyopaque, channel_or_table: []const u8) usize,
        deinit: *const fn (ctx: *anyopaque) void,

        // ── Legacy optional extension (pre-009A, kept for backward compat) ─────────
        writePayloadWithParams: ?*const fn (ctx: *anyopaque, channel_or_table: []const u8, payload: PayloadHandle, params: []const ConfigParam) anyerror!void = null,

        // ── 009A universal contract (optional, null when driver does not support) ──

        /// Return the driver's static capability set.
        getCapabilities: ?*const fn (ctx: *const anyopaque) capabilities.Capabilities = null,

        /// Apply `SchemaCatalog` DDL (CREATE TABLE / INDEX etc.) if the driver has `schema_ddl`.
        ensureSchema: ?*const fn (ctx: *anyopaque, catalog: *const anyopaque) anyerror!void = null,

        /// Engine-agnostic write operation (`WriteSpec` carries mode + payload + RecordMap).
        write: ?*const fn (ctx: *anyopaque, spec: specs.WriteSpec) anyerror!void = null,

        /// Block read (small result sets). Drivers without native streaming read all rows into memory.
        read: ?*const fn (ctx: *anyopaque, allocator: Allocator, spec: specs.ReadSpec) anyerror!PayloadHandle = null,

        /// Streaming cursor read. Returns a `RowIterator` that yields rows lazily.
        readStream: ?*const fn (ctx: *anyopaque, allocator: Allocator, spec: specs.ReadSpec) anyerror!@import("row_iterator.zig").RowIterator = null,

        // ── Optional transaction hooks (null when capabilities().transactions == false) ──
        beginTx: ?*const fn (ctx: *anyopaque) anyerror!void = null,
        commit: ?*const fn (ctx: *anyopaque) anyerror!void = null,
        rollback: ?*const fn (ctx: *anyopaque) anyerror!void = null,

        // ── Optional savepoint hooks (null when capabilities().savepoints == false) ──
        beginSavepoint: ?*const fn (ctx: *anyopaque, name: []const u8) anyerror!void = null,
        rollbackSavepoint: ?*const fn (ctx: *anyopaque, name: []const u8) anyerror!void = null,
        releaseSavepoint: ?*const fn (ctx: *anyopaque, name: []const u8) anyerror!void = null,
    };

    pub const RepositoryVTable = VTable;
    pub const StorageRepositoryVTable = VTable;

    // ── Legacy dispatch helpers ───────────────────────────────────────────────────

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

    pub fn count(self: Repository, table: []const u8) usize {
        return self.vtable.recordCount(self.ptr, table);
    }

    pub fn deinit(self: Repository) void {
        self.vtable.deinit(self.ptr);
    }

    // ── 009A universal contract dispatch helpers ──────────────────────────────────

    /// Returns the driver's declared capabilities. Defaults to all-false when the
    /// driver has not implemented `getCapabilities`.
    pub fn getCapabilities(self: Repository) capabilities.Capabilities {
        const f = self.vtable.getCapabilities orelse return .{};
        return f(self.ptr);
    }

    /// Apply `SchemaCatalog` DDL or register tables with the driver.
    pub fn ensureSchema(self: Repository, catalog: *const anyopaque) !void {
        if (self.vtable.ensureSchema) |f| try f(self.ptr, catalog);
    }

    /// Engine-agnostic write. Falls back to legacy `writePayload` when `write` is not implemented.
    pub fn write(self: Repository, ws: specs.WriteSpec) !void {
        if (self.vtable.write) |f| {
            try f(self.ptr, ws);
        } else {
            try self.vtable.writePayload(self.ptr, ws.table, ws.payload);
        }
    }

    /// Block read. Returns `error.ReadNotSupported` when neither `read` nor `readPayload`
    /// can satisfy the spec (i.e. the driver is write-only).
    pub fn read(self: Repository, allocator: Allocator, rs: specs.ReadSpec) !PayloadHandle {
        if (self.vtable.read) |f| return f(self.ptr, allocator, rs);
        // Legacy fallback: treat the table as a channel
        return self.vtable.readPayload(self.ptr, rs.table) orelse error.RowNotFound;
    }

    /// Streaming read. Falls back to block `read()` wrapped in a slice iterator when
    /// the driver has not implemented `readStream`.
    pub fn readStream(self: Repository, allocator: Allocator, rs: specs.ReadSpec) !@import("row_iterator.zig").RowIterator {
        if (self.vtable.readStream) |f| return f(self.ptr, allocator, rs);
        // Fallback: block-read the whole result then wrap in a one-shot iterator
        const payload = try self.read(allocator, rs);
        return sliceIterator(allocator, payload);
    }

    /// Transaction helpers — no-ops when the driver is non-transactional.
    pub fn beginTx(self: Repository) !void {
        if (self.vtable.beginTx) |f| try f(self.ptr);
    }
    pub fn commit(self: Repository) !void {
        if (self.vtable.commit) |f| try f(self.ptr);
    }
    pub fn rollback(self: Repository) !void {
        if (self.vtable.rollback) |f| try f(self.ptr);
    }

    /// Savepoint helpers — no-ops when the driver does not support savepoints.
    pub fn beginSavepoint(self: Repository, name: []const u8) !void {
        if (self.vtable.beginSavepoint) |f| try f(self.ptr, name);
    }
    pub fn rollbackSavepoint(self: Repository, name: []const u8) !void {
        if (self.vtable.rollbackSavepoint) |f| try f(self.ptr, name);
    }
    pub fn releaseSavepoint(self: Repository, name: []const u8) !void {
        if (self.vtable.releaseSavepoint) |f| try f(self.ptr, name);
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

// ── Fallback slice-based RowIterator (used by readStream fallback) ────────────

const RowIterator = @import("row_iterator.zig").RowIterator;

const SliceIter = struct {
    payload: PayloadHandle,
    done: bool = false,

    fn next(ctx: *anyopaque) anyerror!?PayloadHandle {
        const self: *SliceIter = @ptrCast(@alignCast(ctx));
        if (self.done) return null;
        self.done = true;
        return self.payload;
    }

    fn deinit(ctx: *anyopaque) void {
        _ = ctx; // allocator-managed by caller
    }

    const vtable = RowIterator.VTable{
        .next = next,
        .deinit = deinit,
    };
};

fn sliceIterator(allocator: Allocator, payload: PayloadHandle) !RowIterator {
    const iter = try allocator.create(SliceIter);
    iter.* = .{ .payload = payload };
    return .{ .ptr = iter, .vtable = &SliceIter.vtable };
}
