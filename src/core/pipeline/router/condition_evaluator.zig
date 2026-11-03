const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite_core = @import("../../sqlite/mod.zig");
const Value = sqlite_core.Value;
const binding_mod = @import("../binding/mod.zig");
const InputResolver = binding_mod.InputResolver;

pub const ComparisonOp = enum {
    eq,
    ne,
    gte,
    lte,
    gt,
    lt,
    truthy,
};

/// Evaluates whether `expr` represents a SQL query (`SELECT ...`) or an in-memory condition.
pub fn isSqlQuery(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    return std.ascii.startsWithIgnoreCase(trimmed, "select");
}

/// Evaluates an in-memory router condition against `resolver` without database roundtrips.
/// Supports `or` / `and` combinators, comparisons (`==`, `!=`, `>=`, `<=`, `>`, `<`),
/// and string literals, numbers, booleans, or verdict names (`'DROP'`, `'FLAGGED'`, `'PASS'`).
pub fn evaluateCondition(
    arena: Allocator,
    expr: []const u8,
    resolver: *const InputResolver,
) bool {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len == 0) return false;

    // 1. Evaluate top-level OR clauses: any clause true -> whole expression true
    var or_it = splitCaseInsensitive(trimmed, " or ");
    while (or_it.next()) |or_clause| {
        if (evaluateAndClause(arena, or_clause, resolver)) {
            return true;
        }
    }

    return false;
}

fn evaluateAndClause(arena: Allocator, clause: []const u8, resolver: *const InputResolver) bool {
    // 2. Evaluate AND subclauses: all must be true
    var and_it = splitCaseInsensitive(std.mem.trim(u8, clause, " \t\r\n"), " and ");
    while (and_it.next()) |and_sub| {
        if (!evaluateSingleComparison(arena, and_sub, resolver)) {
            return false;
        }
    }
    return true;
}

fn evaluateSingleComparison(arena: Allocator, raw_clause: []const u8, resolver: *const InputResolver) bool {
    const c = std.mem.trim(u8, raw_clause, " \t\r\n");
    if (c.len == 0) return false;

    // Detect comparison operator
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
        // Truthy check: value must exist and be true / non-zero
        const val = resolver.resolveRawValue(arena, c) catch null orelse return false;
        return switch (val) {
            .boolean => |b| b,
            .int64 => |i| i != 0,
            .float64 => |f| f != 0.0,
            .text => |t| t.len > 0,
            .blob => |b| b.len > 0,
            .null_val => false,
        };
    }

    const lhs_path = std.mem.trim(u8, c[0..op_idx], " \t\r\n");
    const rhs_raw = std.mem.trim(u8, c[op_idx + op_len ..], " \t\r\n");

    const lhs_val = resolver.resolveRawValue(arena, lhs_path) catch null orelse return false;

    return compareValues(lhs_val, op, rhs_raw);
}

fn compareValues(lhs: Value, op: ComparisonOp, rhs_raw: []const u8) bool {
    // 1. Check for quoted string literal: `'...'` or `"..."`
    if ((std.mem.startsWith(u8, rhs_raw, "'") and std.mem.endsWith(u8, rhs_raw, "'")) or
        (std.mem.startsWith(u8, rhs_raw, "\"") and std.mem.endsWith(u8, rhs_raw, "\"")))
    {
        const inner_str = rhs_raw[1 .. rhs_raw.len - 1];

        // Handle string comparison
        if (lhs == .text) {
            const matches = std.mem.eql(u8, lhs.text, inner_str);
            return if (op == .eq) matches else if (op == .ne) !matches else false;
        }

        // Special case: verdict integer comparison with enum name ('DROP' = 2, 'FLAGGED' = 1, 'PASS' = 0)
        if (lhs == .int64) {
            const maybe_verdict_int: ?i64 = if (std.ascii.eqlIgnoreCase(inner_str, "DROP"))
                2
            else if (std.ascii.eqlIgnoreCase(inner_str, "FLAGGED"))
                1
            else if (std.ascii.eqlIgnoreCase(inner_str, "PASS"))
                0
            else
                null;

            if (maybe_verdict_int) |v_int| {
                return compareInts(lhs.int64, op, v_int);
            }
        }

        return false;
    }

    // 2. Check for boolean literal
    if (std.ascii.eqlIgnoreCase(rhs_raw, "true") or std.ascii.eqlIgnoreCase(rhs_raw, "false")) {
        const rhs_bool = std.ascii.eqlIgnoreCase(rhs_raw, "true");
        const lhs_bool: bool = switch (lhs) {
            .boolean => |b| b,
            .int64 => |i| i != 0,
            else => return false,
        };
        const matches = (lhs_bool == rhs_bool);
        return if (op == .eq) matches else if (op == .ne) !matches else false;
    }

    // 3. Check for integer literal
    if (std.fmt.parseInt(i64, rhs_raw, 10)) |rhs_int| {
        return switch (lhs) {
            .int64 => |lhs_int| compareInts(lhs_int, op, rhs_int),
            .boolean => |lhs_b| compareInts(if (lhs_b) 1 else 0, op, rhs_int),
            .float64 => |lhs_f| compareFloats(lhs_f, op, @floatFromInt(rhs_int)),
            else => false,
        };
    } else |_| {}

    // 4. Check for float literal
    if (std.fmt.parseFloat(f64, rhs_raw)) |rhs_float| {
        const lhs_float: f64 = switch (lhs) {
            .float64 => |f| f,
            .int64 => |i| @floatFromInt(i),
            else => return false,
        };
        return compareFloats(lhs_float, op, rhs_float);
    } else |_| {}

    // 5. Bare string literal (e.g. `isobmff`, `ebml`, `riff`)
    if (lhs == .text) {
        const matches = std.mem.eql(u8, lhs.text, rhs_raw);
        return if (op == .eq) matches else if (op == .ne) !matches else false;
    }

    return false;
}

fn compareInts(a: i64, op: ComparisonOp, b: i64) bool {
    return switch (op) {
        .eq => a == b,
        .ne => a != b,
        .gte => a >= b,
        .lte => a <= b,
        .gt => a > b,
        .lt => a < b,
        .truthy => a != 0,
    };
}

fn compareFloats(a: f64, op: ComparisonOp, b: f64) bool {
    return switch (op) {
        .eq => a == b,
        .ne => a != b,
        .gte => a >= b,
        .lte => a <= b,
        .gt => a > b,
        .lt => a < b,
        .truthy => a != 0.0,
    };
}

const CaseInsensitiveSplitter = struct {
    haystack: []const u8,
    delimiter: []const u8,
    index: usize = 0,

    fn next(self: *CaseInsensitiveSplitter) ?[]const u8 {
        if (self.index >= self.haystack.len) return null;

        const remaining = self.haystack[self.index..];
        const match_pos = findCaseInsensitive(remaining, self.delimiter);

        if (match_pos) |pos| {
            const token = remaining[0..pos];
            self.index += pos + self.delimiter.len;
            return token;
        } else {
            self.index = self.haystack.len;
            return remaining;
        }
    }
};

fn splitCaseInsensitive(haystack: []const u8, delimiter: []const u8) CaseInsensitiveSplitter {
    return .{
        .haystack = haystack,
        .delimiter = delimiter,
    };
}

fn findCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    const max_idx = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= max_idx) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return i;
        }
    }
    return null;
}
