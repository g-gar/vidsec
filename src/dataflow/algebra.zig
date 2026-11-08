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

/// Zero-copy slice of a type-erased `PayloadHandle` stream without dynamic allocations.
pub fn slicePayload(payload: types.PayloadHandle, offset: usize, count: usize) types.PayloadHandle {
    if (!payload.is_stream or payload.len == 0 or offset >= payload.len or payload.element_size == 0) {
        return .{
            .ptr = payload.ptr,
            .len = 0,
            .is_stream = payload.is_stream,
            .type_name = payload.type_name,
            .element_size = payload.element_size,
            .element_align = payload.element_align,
            .reflect_fn = payload.reflect_fn,
            .reflect_ctx = payload.reflect_ctx,
            .reflect_ctx_fn = payload.reflect_ctx_fn,
        };
    }
    const end = @min(offset + count, payload.len);
    const new_len = end - offset;
    const byte_offset = offset * payload.element_size;
    const base_bytes: [*]const u8 = @ptrCast(payload.ptr);
    const new_ptr: *const anyopaque = @ptrCast(base_bytes + byte_offset);

    return .{
        .ptr = new_ptr,
        .len = new_len,
        .is_stream = true,
        .type_name = payload.type_name,
        .element_size = payload.element_size,
        .element_align = payload.element_align,
        .reflect_fn = payload.reflect_fn,
        .reflect_ctx = payload.reflect_ctx,
        .reflect_ctx_fn = payload.reflect_ctx_fn,
    };
}

/// Merges multiple compatible type-erased `PayloadHandle` streams into a single contiguous buffer.
pub fn mergePayloads(allocator: Allocator, payloads: []const types.PayloadHandle) Allocator.Error!types.PayloadHandle {
    if (payloads.len == 0) {
        return .{
            .ptr = &{},
            .len = 0,
            .is_stream = true,
            .type_name = "unknown",
            .element_size = 0,
            .element_align = 1,
        };
    }
    if (payloads.len == 1) return payloads[0];

    const first = payloads[0];
    const elem_size = first.element_size;
    const elem_align = first.element_align;

    var total_len: usize = 0;
    for (payloads) |p| {
        total_len += p.len;
    }

    if (total_len == 0 or elem_size == 0) return first;

    const total_bytes = total_len * elem_size;
    const raw_buf = try allocator.alignedAlloc(u8, .@"16", total_bytes);
    errdefer allocator.free(raw_buf);

    var byte_offset: usize = 0;
    for (payloads) |p| {
        if (p.len > 0 and p.element_size == elem_size) {
            const p_bytes = p.len * elem_size;
            const src: [*]const u8 = @ptrCast(p.ptr);
            @memcpy(raw_buf[byte_offset .. byte_offset + p_bytes], src[0..p_bytes]);
            byte_offset += p_bytes;
        }
    }

    return .{
        .ptr = @ptrCast(raw_buf.ptr),
        .len = total_len,
        .is_stream = true,
        .type_name = first.type_name,
        .element_size = elem_size,
        .element_align = elem_align,
        .reflect_fn = first.reflect_fn,
        .reflect_ctx = first.reflect_ctx,
        .reflect_ctx_fn = first.reflect_ctx_fn,
    };
}
