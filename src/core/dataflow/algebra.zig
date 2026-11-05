const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const reflectField = types.reflectField;

pub const AlgebraError = error{
    OutOfMemory,
    KeyNotFoundInRecord,
    TypeMismatchInJoinKey,
};

/// Merges multiple native streams of type `T` into a single consolidated slice.
/// Allocates one contiguous slice and copies values with zero boxing.
pub fn merge(comptime T: type, allocator: Allocator, streams: []const []const T) Allocator.Error![]const T {
    var total_len: usize = 0;
    for (streams) |s| {
        total_len += s.len;
    }

    const result = try allocator.alloc(T, total_len);
    errdefer allocator.free(result);

    var offset: usize = 0;
    for (streams) |s| {
        @memcpy(result[offset .. offset + s.len], s);
        offset += s.len;
    }

    return result;
}

/// Generic pair struct representing 1:1 aligned records from two streams.
pub fn Pair(comptime A: type, comptime B: type) type {
    return struct {
        first: A,
        second: B,
    };
}

/// Pairs elements of stream `a` and stream `b` by index (1:1 alignment) without boxing.
pub fn zip(
    comptime A: type,
    comptime B: type,
    allocator: Allocator,
    a: []const A,
    b: []const B,
) Allocator.Error![]const Pair(A, B) {
    const pair_count = @min(a.len, b.len);
    const result = try allocator.alloc(Pair(A, B), pair_count);
    errdefer allocator.free(result);

    for (0..pair_count) |i| {
        result[i] = .{
            .first = a[i],
            .second = b[i],
        };
    }

    return result;
}

/// Generic container for the result of an equi-join between two native structs.
pub fn Joined(comptime A: type, comptime B: type) type {
    return struct {
        left: A,
        right: B,
    };
}

/// Performs a hash equi-join between native stream `a` and stream `b` matching
/// `key_a` on `A` with `key_b` on `B` using compile-time reflection.
pub fn join(
    comptime A: type,
    comptime B: type,
    comptime key_a: []const u8,
    comptime key_b: []const u8,
    allocator: Allocator,
    a: []const A,
    b: []const B,
) AlgebraError![]const Joined(A, B) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    var b_int_map: std.AutoHashMapUnmanaged(i64, B) = .empty;
    var b_str_map: std.StringHashMapUnmanaged(B) = .empty;

    for (b) |item_b| {
        const val = reflectField(B, &item_b, key_b) orelse continue;
        switch (val) {
            .int => |iv| try b_int_map.put(temp, iv, item_b),
            .uint => |uv| try b_int_map.put(temp, @intCast(uv), item_b),
            .string => |sv| try b_str_map.put(temp, sv, item_b),
            else => {},
        }
    }

    var joined: std.ArrayListUnmanaged(Joined(A, B)) = .empty;
    errdefer joined.deinit(allocator);

    for (a) |item_a| {
        const val_a = reflectField(A, &item_a, key_a) orelse continue;
        const match_b: ?B = switch (val_a) {
            .int => |iv| b_int_map.get(iv),
            .uint => |uv| b_int_map.get(@intCast(uv)),
            .string => |sv| b_str_map.get(sv),
            else => null,
        };

        if (match_b) |found_b| {
            try joined.append(allocator, .{
                .left = item_a,
                .right = found_b,
            });
        }
    }

    return joined.toOwnedSlice(allocator);
}

/// Zero-copy slice of a native stream up to `count` elements starting at `offset`.
pub fn slice(comptime T: type, items: []const T, offset: usize, count: usize) []const T {
    if (offset >= items.len) return &.{};
    const end = @min(offset + count, items.len);
    return items[offset..end];
}
