const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const ReflectedValue = types.ReflectedValue;
const reflectField = types.reflectField;

pub const ComparisonOp = enum {
    eq,
    ne,
    gte,
    lte,
    gt,
    lt,
    truthy,
};

/// Evaluates a declarative predicate condition (e.g. `role == 'padding' and score >= 0.8`)
/// directly against any native Zig struct using compile-time reflection (zero boxing).
pub fn evaluatePredicate(comptime T: type, item: *const T, expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len == 0) return true;

    // 1. Evaluate top-level OR: any true clause satisfies the predicate
    var or_it = splitCaseInsensitive(trimmed, " or ");
    while (or_it.next()) |or_clause| {
        if (evaluateAndClause(T, item, or_clause)) {
            return true;
        }
    }

    return false;
}

/// Evaluates a declarative predicate condition directly against a type-erased PayloadHandle
/// using the handle's compile-time reflection callback (zero boxing).
pub fn evaluatePredicateHandle(payload: types.PayloadHandle, expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len == 0) return true;

    var or_it = splitCaseInsensitive(trimmed, " or ");
    while (or_it.next()) |or_clause| {
        if (evaluateAndClauseHandle(payload, or_clause)) {
            return true;
        }
    }
    return false;
}

/// Filters a stream of native structs `T`, returning only those matching `predicate_expr`.
pub fn filterStream(
    comptime T: type,
    allocator: Allocator,
    stream: []const T,
    predicate_expr: []const u8,
) Allocator.Error![]const T {
    const trimmed = std.mem.trim(u8, predicate_expr, " \t\r\n");
    if (trimmed.len == 0) return stream;

    var filtered: std.ArrayListUnmanaged(T) = .empty;
    errdefer filtered.deinit(allocator);

    for (stream) |item| {
        if (evaluatePredicate(T, &item, trimmed)) {
            try filtered.append(allocator, item);
        }
    }

    return filtered.toOwnedSlice(allocator);
}

fn evaluateAndClause(comptime T: type, item: *const T, clause: []const u8) bool {
    var and_it = splitCaseInsensitive(std.mem.trim(u8, clause, " \t\r\n"), " and ");
    while (and_it.next()) |and_sub| {
        if (!evaluateSingleComparison(T, item, and_sub)) {
            return false;
        }
    }
    return true;
}

fn evaluateAndClauseHandle(payload: types.PayloadHandle, clause: []const u8) bool {
    var and_it = splitCaseInsensitive(std.mem.trim(u8, clause, " \t\r\n"), " and ");
    while (and_it.next()) |and_sub| {
        if (!evaluateSingleComparisonHandle(payload, and_sub)) {
            return false;
        }
    }
    return true;
}

fn evaluateSingleComparison(comptime T: type, item: *const T, raw_clause: []const u8) bool {
    const c = std.mem.trim(u8, raw_clause, " \t\r\n");
    if (c.len == 0) return true;

    var op: ComparisonOp = .truthy;
    var op_idx: usize = 0;
    var op_len: usize = 0;

    if (std.mem.indexOf(u8, c, "==")) |idx| {
        op = .eq;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, c, "!=")) |idx| {
        op = .ne;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, c, ">=")) |idx| {
        op = .gte;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, c, "<=")) |idx| {
        op = .lte;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, c, ">")) |idx| {
        op = .gt;
        op_idx = idx;
        op_len = 1;
    } else if (std.mem.indexOf(u8, c, "<")) |idx| {
        op = .lt;
        op_idx = idx;
        op_len = 1;
    }

    if (op == .truthy) {
        const val = resolveOperand(T, item, c);
        return val.isTruthy();
    }

    const lhs_raw = std.mem.trim(u8, c[0..op_idx], " \t\r\n");
    const rhs_raw = std.mem.trim(u8, c[op_idx + op_len ..], " \t\r\n");

    const lhs = resolveOperand(T, item, lhs_raw);
    const rhs = resolveOperand(T, item, rhs_raw);

    return switch (op) {
        .eq => lhs.equals(rhs),
        .ne => !lhs.equals(rhs),
        .gte => compareOrdered(lhs, rhs) != .less,
        .lte => compareOrdered(lhs, rhs) != .greater,
        .gt => compareOrdered(lhs, rhs) == .greater,
        .lt => compareOrdered(lhs, rhs) == .less,
        .truthy => unreachable,
    };
}

fn evaluateSingleComparisonHandle(payload: types.PayloadHandle, raw_clause: []const u8) bool {
    const c = std.mem.trim(u8, raw_clause, " \t\r\n");
    if (c.len == 0) return true;

    var op: ComparisonOp = .truthy;
    var op_idx: usize = 0;
    var op_len: usize = 0;

    if (std.mem.indexOf(u8, c, "==")) |idx| {
        op = .eq;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, c, "!=")) |idx| {
        op = .ne;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, c, ">=")) |idx| {
        op = .gte;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, c, "<=")) |idx| {
        op = .lte;
        op_idx = idx;
        op_len = 2;
    } else if (std.mem.indexOf(u8, c, ">")) |idx| {
        op = .gt;
        op_idx = idx;
        op_len = 1;
    } else if (std.mem.indexOf(u8, c, "<")) |idx| {
        op = .lt;
        op_idx = idx;
        op_len = 1;
    }

    if (op == .truthy) {
        const val = resolveOperandHandle(payload, c);
        return val.isTruthy();
    }

    const lhs_raw = std.mem.trim(u8, c[0..op_idx], " \t\r\n");
    const rhs_raw = std.mem.trim(u8, c[op_idx + op_len ..], " \t\r\n");

    const lhs = resolveOperandHandle(payload, lhs_raw);
    const rhs = resolveOperandHandle(payload, rhs_raw);

    return switch (op) {
        .eq => lhs.equals(rhs),
        .ne => !lhs.equals(rhs),
        .gte => compareOrdered(lhs, rhs) != .less,
        .lte => compareOrdered(lhs, rhs) != .greater,
        .gt => compareOrdered(lhs, rhs) == .greater,
        .lt => compareOrdered(lhs, rhs) == .less,
        .truthy => unreachable,
    };
}

const OrderedCmp = enum { less, equal, greater, incomparable };

fn compareOrdered(lhs: ReflectedValue, rhs: ReflectedValue) OrderedCmp {
    const l_float = lhs.asFloat();
    const r_float = rhs.asFloat();

    if (l_float != null and r_float != null) {
        if (l_float.? < r_float.?) return .less;
        if (l_float.? > r_float.?) return .greater;
        return .equal;
    }

    const l_str = lhs.asString();
    const r_str = rhs.asString();
    if (l_str != null and r_str != null) {
        const order = std.mem.order(u8, l_str.?, r_str.?);
        return switch (order) {
            .lt => .less,
            .gt => .greater,
            .eq => .equal,
        };
    }

    return .incomparable;
}

fn resolveOperand(comptime T: type, item: *const T, token: []const u8) ReflectedValue {
    const t = std.mem.trim(u8, token, " \t\r\n");

    // 1. Quoted string literals: 'text' or "text"
    if ((std.mem.startsWith(u8, t, "'") and std.mem.endsWith(u8, t, "'")) or
        (std.mem.startsWith(u8, t, "\"") and std.mem.endsWith(u8, t, "\"")))
    {
        if (t.len >= 2) {
            return ReflectedValue.fromString(t[1 .. t.len - 1]);
        }
    }

    // 2. Boolean literals
    if (std.mem.eql(u8, t, "true")) return ReflectedValue.fromBool(true);
    if (std.mem.eql(u8, t, "false")) return ReflectedValue.fromBool(false);
    if (std.mem.eql(u8, t, "null")) return .{ .none = {} };

    // 3. Integer numbers
    if (std.fmt.parseInt(i64, t, 10)) |iv| {
        return ReflectedValue.fromInt(iv);
    } else |_| {}

    // 4. Floating point numbers
    if (std.fmt.parseFloat(f64, t)) |fv| {
        return ReflectedValue.fromFloat(fv);
    } else |_| {}

    // 5. Field access on the native struct (e.g. `role` or `box.role` or `item.role`)
    var field_name = t;
    if (std.mem.lastIndexOf(u8, t, ".")) |dot_idx| {
        field_name = t[dot_idx + 1 ..];
    }

    return reflectField(T, item, field_name) orelse .{ .none = {} };
}

fn resolveOperandHandle(payload: types.PayloadHandle, token: []const u8) ReflectedValue {
    const t = std.mem.trim(u8, token, " \t\r\n");

    // 1. Quoted string literals: 'text' or "text"
    if ((std.mem.startsWith(u8, t, "'") and std.mem.endsWith(u8, t, "'")) or
        (std.mem.startsWith(u8, t, "\"") and std.mem.endsWith(u8, t, "\"")))
    {
        if (t.len >= 2) {
            return ReflectedValue.fromString(t[1 .. t.len - 1]);
        }
    }

    // 2. Boolean literals
    if (std.mem.eql(u8, t, "true")) return ReflectedValue.fromBool(true);
    if (std.mem.eql(u8, t, "false")) return ReflectedValue.fromBool(false);
    if (std.mem.eql(u8, t, "null")) return .{ .none = {} };

    // 3. Integer numbers
    if (std.fmt.parseInt(i64, t, 10)) |iv| {
        return ReflectedValue.fromInt(iv);
    } else |_| {}

    // 4. Floating point numbers
    if (std.fmt.parseFloat(f64, t)) |fv| {
        return ReflectedValue.fromFloat(fv);
    } else |_| {}

    // 5. Built-in `count(...)` aggregation function over the active stream/slice
    if (std.mem.startsWith(u8, t, "count(") and std.mem.endsWith(u8, t, ")")) {
        return ReflectedValue.fromInt(@as(i64, @intCast(payload.len)));
    }

    // 6. Field access on the type-erased payload handle
    var field_name = t;
    if (std.mem.lastIndexOf(u8, t, ".")) |dot_idx| {
        field_name = t[dot_idx + 1 ..];
    }

    return payload.getReflected(field_name) orelse .{ .none = {} };
}

pub fn splitCaseInsensitive(haystack: []const u8, needle: []const u8) CaseInsensitiveSplitIterator {
    return .{
        .haystack = haystack,
        .needle = needle,
        .index = 0,
    };
}

pub const CaseInsensitiveSplitIterator = struct {
    haystack: []const u8,
    needle: []const u8,
    index: ?usize,

    pub fn next(self: *CaseInsensitiveSplitIterator) ?[]const u8 {
        const start = self.index orelse return null;
        if (start >= self.haystack.len) {
            self.index = null;
            return null;
        }

        const remaining = self.haystack[start..];
        if (indexOfCaseInsensitive(remaining, self.needle)) |offset| {
            const end = start + offset;
            self.index = end + self.needle.len;
            return self.haystack[start..end];
        } else {
            self.index = null;
            return self.haystack[start..];
        }
    }
};

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;

    const max_idx = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= max_idx) : (i += 1) {
        var match = true;
        for (needle, 0..) |n_ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(n_ch)) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

/// Filters a `PayloadHandle` (either stream or scalar) according to declarative boolean expression `predicate_expr`.
pub fn filterPayload(allocator: Allocator, payload: types.PayloadHandle, predicate_expr: []const u8) Allocator.Error!types.PayloadHandle {
    const expr_trimmed = std.mem.trim(u8, predicate_expr, " \t\r\n");
    if (expr_trimmed.len == 0) return payload;

    if (!payload.is_stream or payload.len <= 1) {
        if (evaluatePredicateHandle(payload, expr_trimmed)) {
            return payload;
        } else {
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
    }

    const elem_size = payload.element_size;
    const elem_align = payload.element_align;
    const base_bytes: [*]const u8 = @ptrCast(payload.ptr);

    var matched_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer matched_indices.deinit(allocator);

    for (0..payload.len) |i| {
        const item_ptr: *const anyopaque = @ptrCast(base_bytes + (i * elem_size));
        const item_handle = types.PayloadHandle{
            .ptr = item_ptr,
            .len = 1,
            .is_stream = false,
            .type_name = payload.type_name,
            .element_size = elem_size,
            .element_align = elem_align,
            .reflect_fn = payload.reflect_fn,
            .reflect_ctx = payload.reflect_ctx,
            .reflect_ctx_fn = payload.reflect_ctx_fn,
        };

        if (evaluatePredicateHandle(item_handle, expr_trimmed)) {
            try matched_indices.append(allocator, i);
        }
    }

    if (matched_indices.items.len == payload.len) {
        return payload;
    }

    const out_buf = try allocator.alignedAlloc(u8, .@"16", matched_indices.items.len * elem_size);
    errdefer allocator.free(out_buf);

    for (matched_indices.items, 0..) |orig_idx, out_idx| {
        const src_start = orig_idx * elem_size;
        const dst_start = out_idx * elem_size;
        @memcpy(out_buf[dst_start .. dst_start + elem_size], base_bytes[src_start .. src_start + elem_size]);
    }

    return .{
        .ptr = @ptrCast(out_buf.ptr),
        .len = matched_indices.items.len,
        .is_stream = true,
        .type_name = payload.type_name,
        .element_size = elem_size,
        .element_align = elem_align,
        .reflect_fn = payload.reflect_fn,
        .reflect_ctx = payload.reflect_ctx,
        .reflect_ctx_fn = payload.reflect_ctx_fn,
    };
}
