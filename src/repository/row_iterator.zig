const std = @import("std");
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;

/// Streaming row iterator returned by `Repository.readStream()`.
///
/// Drivers implement this interface to yield rows lazily (cursor stepping), enabling
/// O(1) memory consumption for large reads and DAG scheduler backpressure integration.
///
/// Drivers that do not natively support streaming (i.e. `capabilities().streaming == false`)
/// wrap a fully-fetched in-memory slice; the caller code is identical regardless.
///
/// Typical usage:
/// ```zig
/// var it = try repo.readStream(spec);
/// defer it.deinit();
/// while (try it.next()) |row| {
///     _ = row; // process PayloadHandle chunk
/// }
/// ```
pub const RowIterator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Advance and return the next row (or batch chunk), or `null` when exhausted.
        /// Returns `anyerror` for I/O or deserialization failures.
        next: *const fn (ctx: *anyopaque) anyerror!?PayloadHandle,
        /// Release driver-side cursor resources (statement, file descriptor, etc.).
        deinit: *const fn (ctx: *anyopaque) void,
        /// Optional: estimated total row count. Returns `null` when unknown (e.g. streaming HTTP).
        estimatedCount: ?*const fn (ctx: *const anyopaque) ?usize = null,
    };

    pub fn next(self: RowIterator) !?PayloadHandle {
        return self.vtable.next(self.ptr);
    }

    pub fn deinit(self: RowIterator) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn estimatedCount(self: RowIterator) ?usize {
        const f = self.vtable.estimatedCount orelse return null;
        return f(self.ptr);
    }

    /// Collect all remaining rows into an `ArrayList`. Convenience method for
    /// small result sets or tests; for large datasets prefer stepping with `next()`.
    pub fn collectAll(self: RowIterator, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(PayloadHandle) {
        var list: std.ArrayListUnmanaged(PayloadHandle) = .empty;
        errdefer list.deinit(allocator);
        while (try self.next()) |row| {
            try list.append(allocator, row);
        }
        return list;
    }
};

