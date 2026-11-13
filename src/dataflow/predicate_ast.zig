/// Predicate AST — ARCH-009A §2.3
///
/// A portable, engine-agnostic representation of filter predicates declared in
/// `pipeline.yaml` (`where: "status == 'active' and age >= 18"`).
///
/// # Frontends
/// - `PredicateParser.fromExpr(arena, expr)` — parses the declarative string syntax
///   into a `PredicateNode` tree using an arena allocator (zero per-node heap overhead).
/// - `PredicateBuilder` — programmatic builder for compile-time / test construction.
///
/// # Backends
/// - **In-memory evaluator:** `evalNode(node, getter)` — pure evaluator for
///   `MemoryRepository`, in-process filters, and drivers without pushdown.
/// - **SQL pushdown:** Drivers with `capabilities().filter_pushdown` compile the
///   AST to parameterized SQL (`WHERE "status" = ?1 AND "age" >= ?2`) in
///   `extensions/datasource/sqlite/src/predicate_compiler.zig` (ARCH-009B).
///
/// Maintaining backward compatibility: the existing `evaluatePredicate` / `evaluatePredicateHandle`
/// string-splitting evaluators in `predicate.zig` remain untouched and are still used for
/// legacy code paths. New code should use `PredicateParser.fromExpr` + `evalNode`.
const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Literal value types ───────────────────────────────────────────────────────

/// A typed literal value in a predicate expression.
pub const Literal = union(enum) {
    null_val,
    int64: i64,
    float64: f64,
    boolean: bool,
    text: []const u8,

    pub fn format(self: Literal, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .null_val => try writer.writeAll("NULL"),
            .int64 => |v| try writer.print("{d}", .{v}),
            .float64 => |v| try writer.print("{d}", .{v}),
            .boolean => |v| try writer.writeAll(if (v) "true" else "false"),
            .text => |v| try writer.print("'{s}'", .{v}),
        }
    }
};

// ── Comparison operators ──────────────────────────────────────────────────────

pub const CmpOp = enum {
    eq,  // ==
    ne,  // !=
    lt,  // <
    lte, // <=
    gt,  // >
    gte, // >=
};

// ── Predicate AST node ────────────────────────────────────────────────────────

/// A node in the Predicate AST.
///
/// Nodes are arena-allocated; callers own the arena lifetime. All string slices
/// point into either the arena or the original expression string (zero-copy).
pub const PredicateNode = union(enum) {
    /// Logical AND of two sub-trees.
    @"and": BinaryLogical,
    /// Logical OR of two sub-trees.
    @"or": BinaryLogical,
    /// Logical NOT of a sub-tree.
    not: *PredicateNode,
    /// Column `op` literal comparison  (e.g. `age >= 18`).
    cmp: Comparison,
    /// Column IS NULL.
    is_null: []const u8,
    /// Column IS NOT NULL.
    is_not_null: []const u8,
    /// Column IN (...) set membership.
    in_list: InList,
    /// Literal `true` / `false` (useful for constant-folded sub-trees).
    literal: bool,

    pub const BinaryLogical = struct {
        left: *PredicateNode,
        right: *PredicateNode,
    };

    pub const Comparison = struct {
        /// The column name on the left-hand side.
        column: []const u8,
        op: CmpOp,
        value: Literal,
    };

    pub const InList = struct {
        column: []const u8,
        values: []const Literal,
    };
};

// ── In-memory evaluator ───────────────────────────────────────────────────────

/// Generic field-value getter callback.
/// Returns the field value as a `?Literal`, or `null` if the field does not exist.
pub const FieldGetter = *const fn (ctx: *const anyopaque, column: []const u8) ?Literal;

/// Evaluate a `PredicateNode` against a row described by `getter(ctx, column)`.
/// Pure: no allocations, no I/O.
pub fn evalNode(node: *const PredicateNode, getter: FieldGetter, ctx: *const anyopaque) bool {
    return switch (node.*) {
        .literal => |v| v,

        .not => |child| !evalNode(child, getter, ctx),

        .@"and" => |b| evalNode(b.left, getter, ctx) and evalNode(b.right, getter, ctx),

        .@"or" => |b| evalNode(b.left, getter, ctx) or evalNode(b.right, getter, ctx),

        .is_null => |col| getter(ctx, col) == null or getter(ctx, col).? == .null_val,

        .is_not_null => |col| blk: {
            const v = getter(ctx, col) orelse break :blk false;
            break :blk v != .null_val;
        },

        .cmp => |c| blk: {
            const field_val = getter(ctx, c.column) orelse break :blk false;
            break :blk evalCmp(field_val, c.op, c.value);
        },

        .in_list => |il| blk: {
            const field_val = getter(ctx, il.column) orelse break :blk false;
            for (il.values) |candidate| {
                if (literalEq(field_val, candidate)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn evalCmp(lhs: Literal, op: CmpOp, rhs: Literal) bool {
    return switch (op) {
        .eq => literalEq(lhs, rhs),
        .ne => !literalEq(lhs, rhs),
        else => blk: {
            const ord = literalOrder(lhs, rhs) orelse break :blk false;
            break :blk switch (op) {
                .lt => ord == .lt,
                .lte => ord == .lt or ord == .eq,
                .gt => ord == .gt,
                .gte => ord == .gt or ord == .eq,
                else => unreachable,
            };
        },
    };
}

fn literalEq(a: Literal, b: Literal) bool {
    return switch (a) {
        .null_val => b == .null_val,
        .boolean => |av| b == .boolean and b.boolean == av,
        .int64 => |av| switch (b) {
            .int64 => |bv| av == bv,
            .float64 => |bv| @as(f64, @floatFromInt(av)) == bv,
            else => false,
        },
        .float64 => |av| switch (b) {
            .float64 => |bv| av == bv,
            .int64 => |bv| av == @as(f64, @floatFromInt(bv)),
            else => false,
        },
        .text => |av| b == .text and std.mem.eql(u8, av, b.text),
    };
}

const LiteralOrder = enum { lt, eq, gt };

fn literalOrder(a: Literal, b: Literal) ?LiteralOrder {
    switch (a) {
        .int64 => |av| {
            const af: f64 = @floatFromInt(av);
            const bf: f64 = switch (b) {
                .int64 => |bv| @floatFromInt(bv),
                .float64 => |bv| bv,
                else => return null,
            };
            if (af < bf) return .lt;
            if (af > bf) return .gt;
            return .eq;
        },
        .float64 => |av| {
            const bf: f64 = switch (b) {
                .float64 => |bv| bv,
                .int64 => |bv| @floatFromInt(bv),
                else => return null,
            };
            if (av < bf) return .lt;
            if (av > bf) return .gt;
            return .eq;
        },
        .text => |av| {
            if (b != .text) return null;
            return switch (std.mem.order(u8, av, b.text)) {
                .lt => .lt,
                .gt => .gt,
                .eq => .eq,
            };
        },
        else => return null,
    }
}

// ── Predicate Parser ──────────────────────────────────────────────────────────

/// Parser errors.
pub const ParseError = error{
    EmptyExpression,
    UnbalancedParentheses,
    InvalidComparison,
    InvalidLiteral,
    InvalidInList,
    OutOfMemory,
};

/// Parses a declarative predicate string (as used in `pipeline.yaml` `where:` fields)
/// into a `PredicateNode` tree allocated from `arena`.
///
/// Supported syntax:
/// - `col == 'value'` / `col != 42` / `col >= 1.5`
/// - `col IS NULL` / `col IS NOT NULL`
/// - `col IN ('a', 'b', 42)`
/// - `expr AND expr` / `expr OR expr` / `NOT expr`
/// - Parenthesized grouping: `(a == 1 OR b == 2) AND c != 3`
///
/// String literals must be single-quoted (`'value'`). Numbers are parsed as
/// `int64` or `float64` automatically.
pub const PredicateParser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,

    pub fn fromExpr(arena: Allocator, expr: []const u8) ParseError!*PredicateNode {
        const trimmed = std.mem.trim(u8, expr, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyExpression;
        var parser = PredicateParser{ .arena = arena, .src = trimmed };
        return parser.parseOr();
    }

    // ── Recursive descent: OR > AND > NOT > atom ──────────────────────────────

    fn parseOr(self: *PredicateParser) ParseError!*PredicateNode {
        var left = try self.parseAnd();
        while (self.consumeKeyword("OR")) {
            const right = try self.parseAnd();
            const node = try self.arena.create(PredicateNode);
            node.* = .{ .@"or" = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseAnd(self: *PredicateParser) ParseError!*PredicateNode {
        var left = try self.parseNot();
        while (self.consumeKeyword("AND")) {
            const right = try self.parseNot();
            const node = try self.arena.create(PredicateNode);
            node.* = .{ .@"and" = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseNot(self: *PredicateParser) ParseError!*PredicateNode {
        if (self.consumeKeyword("NOT")) {
            const child = try self.parseAtom();
            const node = try self.arena.create(PredicateNode);
            node.* = .{ .not = child };
            return node;
        }
        return self.parseAtom();
    }

    fn parseAtom(self: *PredicateParser) ParseError!*PredicateNode {
        self.skipWs();

        // Parenthesized sub-expression
        if (self.pos < self.src.len and self.src[self.pos] == '(') {
            self.pos += 1;
            const inner = try self.parseOr();
            self.skipWs();
            if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.UnbalancedParentheses;
            self.pos += 1;
            return inner;
        }

        return self.parseComparison();
    }

    fn parseComparison(self: *PredicateParser) ParseError!*PredicateNode {
        self.skipWs();
        const col = self.parseIdentifier() orelse return error.InvalidComparison;
        self.skipWs();

        // IS NULL / IS NOT NULL
        if (self.consumeKeyword("IS")) {
            self.skipWs();
            const is_not = self.consumeKeyword("NOT");
            self.skipWs();
            if (!self.consumeKeyword("NULL")) return error.InvalidComparison;
            const node = try self.arena.create(PredicateNode);
            if (is_not) {
                node.* = .{ .is_not_null = col };
            } else {
                node.* = .{ .is_null = col };
            }
            return node;
        }

        // IN (...)
        if (self.consumeKeyword("IN")) {
            self.skipWs();
            if (self.pos >= self.src.len or self.src[self.pos] != '(') return error.InvalidInList;
            self.pos += 1;
            var values: std.ArrayListUnmanaged(Literal) = .empty;
            while (true) {
                self.skipWs();
                if (self.pos < self.src.len and self.src[self.pos] == ')') {
                    self.pos += 1;
                    break;
                }
                const lit = try self.parseLiteral();
                try values.append(self.arena, lit);
                self.skipWs();
                if (self.pos < self.src.len and self.src[self.pos] == ',') self.pos += 1;
            }
            const node = try self.arena.create(PredicateNode);
            node.* = .{ .in_list = .{
                .column = col,
                .values = try values.toOwnedSlice(self.arena),
            } };
            return node;
        }

        // Comparison operators
        const op = self.parseCmpOp() orelse return error.InvalidComparison;
        self.skipWs();
        const rhs = try self.parseLiteral();

        const node = try self.arena.create(PredicateNode);
        node.* = .{ .cmp = .{ .column = col, .op = op, .value = rhs } };
        return node;
    }

    // ── Tokenizing helpers ────────────────────────────────────────────────────

    fn skipWs(self: *PredicateParser) void {
        while (self.pos < self.src.len and
            (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or
            self.src[self.pos] == '\r' or self.src[self.pos] == '\n'))
        {
            self.pos += 1;
        }
    }

    /// Attempts to consume a case-insensitive keyword followed by a non-identifier character.
    /// Returns true and advances `pos` on success; leaves `pos` unchanged on failure.
    fn consumeKeyword(self: *PredicateParser, kw: []const u8) bool {
        self.skipWs();
        const remaining = self.src[self.pos..];
        if (remaining.len < kw.len) return false;
        const slice = remaining[0..kw.len];
        if (!std.ascii.eqlIgnoreCase(slice, kw)) return false;
        // keyword must not be followed by an identifier character
        if (remaining.len > kw.len and isIdentChar(remaining[kw.len])) return false;
        self.pos += kw.len;
        return true;
    }

    fn parseIdentifier(self: *PredicateParser) ?[]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) {
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return self.src[start..self.pos];
    }

    fn parseCmpOp(self: *PredicateParser) ?CmpOp {
        const remaining = self.src[self.pos..];
        if (std.mem.startsWith(u8, remaining, "==")) { self.pos += 2; return .eq; }
        if (std.mem.startsWith(u8, remaining, "!=")) { self.pos += 2; return .ne; }
        if (std.mem.startsWith(u8, remaining, ">=")) { self.pos += 2; return .gte; }
        if (std.mem.startsWith(u8, remaining, "<=")) { self.pos += 2; return .lte; }
        if (std.mem.startsWith(u8, remaining, ">"))  { self.pos += 1; return .gt; }
        if (std.mem.startsWith(u8, remaining, "<"))  { self.pos += 1; return .lt; }
        return null;
    }

    fn parseLiteral(self: *PredicateParser) ParseError!Literal {
        self.skipWs();
        if (self.pos >= self.src.len) return error.InvalidLiteral;

        const ch = self.src[self.pos];

        // NULL
        if (self.consumeKeyword("NULL")) return .null_val;

        // Boolean
        if (self.consumeKeyword("true")) return .{ .boolean = true };
        if (self.consumeKeyword("false")) return .{ .boolean = false };

        // Single-quoted string
        if (ch == '\'') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '\'') {
                self.pos += 1;
            }
            if (self.pos >= self.src.len) return error.InvalidLiteral;
            const text = self.src[start..self.pos];
            self.pos += 1; // consume closing '
            return .{ .text = text };
        }

        // Number (integer or float)
        const num_start = self.pos;
        if (ch == '-' or ch == '+') self.pos += 1;
        while (self.pos < self.src.len and
            (self.src[self.pos] >= '0' and self.src[self.pos] <= '9')) self.pos += 1;
        const has_dot = self.pos < self.src.len and self.src[self.pos] == '.';
        if (has_dot) {
            self.pos += 1;
            while (self.pos < self.src.len and
                (self.src[self.pos] >= '0' and self.src[self.pos] <= '9')) self.pos += 1;
        }
        if (self.pos == num_start) return error.InvalidLiteral;
        const num_str = self.src[num_start..self.pos];

        if (has_dot) {
            const f = std.fmt.parseFloat(f64, num_str) catch return error.InvalidLiteral;
            return .{ .float64 = f };
        } else {
            const i = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidLiteral;
            return .{ .int64 = i };
        }
    }

    fn isIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
               (c >= '0' and c <= '9') or c == '_' or c == '.';
    }
};

// ── Programmatic builder ──────────────────────────────────────────────────────

/// Programmatic Predicate builder for compile-time / test construction.
///
/// All allocated nodes live in the provided arena.
///
/// ```zig
/// var b = PredicateBuilder.init(arena);
/// const pred = try b.@"and"(
///     try b.cmp("status", .eq, .{ .text = "active" }),
///     try b.cmp("age",    .gte, .{ .int64 = 18 }),
/// );
/// ```
pub const PredicateBuilder = struct {
    arena: Allocator,

    pub fn init(arena: Allocator) PredicateBuilder {
        return .{ .arena = arena };
    }

    pub fn @"and"(self: PredicateBuilder, left: *PredicateNode, right: *PredicateNode) !*PredicateNode {
        const node = try self.arena.create(PredicateNode);
        node.* = .{ .@"and" = .{ .left = left, .right = right } };
        return node;
    }

    pub fn @"or"(self: PredicateBuilder, left: *PredicateNode, right: *PredicateNode) !*PredicateNode {
        const node = try self.arena.create(PredicateNode);
        node.* = .{ .@"or" = .{ .left = left, .right = right } };
        return node;
    }

    pub fn not(self: PredicateBuilder, child: *PredicateNode) !*PredicateNode {
        const node = try self.arena.create(PredicateNode);
        node.* = .{ .not = child };
        return node;
    }

    pub fn cmp(self: PredicateBuilder, column: []const u8, op: CmpOp, value: Literal) !*PredicateNode {
        const node = try self.arena.create(PredicateNode);
        node.* = .{ .cmp = .{ .column = column, .op = op, .value = value } };
        return node;
    }

    pub fn isNull(self: PredicateBuilder, column: []const u8) !*PredicateNode {
        const node = try self.arena.create(PredicateNode);
        node.* = .{ .is_null = column };
        return node;
    }

    pub fn isNotNull(self: PredicateBuilder, column: []const u8) !*PredicateNode {
        const node = try self.arena.create(PredicateNode);
        node.* = .{ .is_not_null = column };
        return node;
    }

    pub fn inList(self: PredicateBuilder, column: []const u8, values: []const Literal) !*PredicateNode {
        const node = try self.arena.create(PredicateNode);
        node.* = .{ .in_list = .{ .column = column, .values = values } };
        return node;
    }

    pub fn literal(self: PredicateBuilder, value: bool) !*PredicateNode {
        const node = try self.arena.create(PredicateNode);
        node.* = .{ .literal = value };
        return node;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "PredicateParser: simple equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try PredicateParser.fromExpr(alloc, "status == 'active'");
    try std.testing.expect(node.* == .cmp);
    try std.testing.expectEqualStrings("status", node.cmp.column);
    try std.testing.expect(node.cmp.op == .eq);
    try std.testing.expectEqualStrings("active", node.cmp.value.text);
}

test "PredicateParser: AND + OR precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // a == 1 OR b == 2 AND c == 3  should parse as  a==1 OR (b==2 AND c==3)
    const node = try PredicateParser.fromExpr(alloc, "a == 1 OR b == 2 AND c == 3");
    try std.testing.expect(node.* == .@"or");
    try std.testing.expect(node.@"or".right.* == .@"and");
}

test "PredicateParser: IS NULL / IS NOT NULL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n1 = try PredicateParser.fromExpr(alloc, "col IS NULL");
    try std.testing.expect(n1.* == .is_null);

    const n2 = try PredicateParser.fromExpr(alloc, "col IS NOT NULL");
    try std.testing.expect(n2.* == .is_not_null);
}

test "PredicateParser: IN list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try PredicateParser.fromExpr(alloc, "status IN ('active', 'pending')");
    try std.testing.expect(node.* == .in_list);
    try std.testing.expectEqualStrings("status", node.in_list.column);
    try std.testing.expectEqual(@as(usize, 2), node.in_list.values.len);
}

test "evalNode: basic comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try PredicateParser.fromExpr(alloc, "age >= 18");

    const Row = struct { age: i64 };
    const row = Row{ .age = 21 };

    const getter: FieldGetter = struct {
        fn get(ctx: *const anyopaque, col: []const u8) ?Literal {
            const r: *const Row = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, col, "age")) return .{ .int64 = r.age };
            return null;
        }
    }.get;

    try std.testing.expect(evalNode(node, getter, &row));
}

test "PredicateBuilder: programmatic AND" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var b = PredicateBuilder.init(alloc);
    const pred = try b.@"and"(
        try b.cmp("status", .eq, .{ .text = "active" }),
        try b.cmp("age", .gte, .{ .int64 = 18 }),
    );

    const Row = struct { status: []const u8, age: i64 };
    const row = Row{ .status = "active", .age = 25 };

    const getter: FieldGetter = struct {
        fn get(ctx: *const anyopaque, col: []const u8) ?Literal {
            const r: *const Row = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, col, "status")) return .{ .text = r.status };
            if (std.mem.eql(u8, col, "age")) return .{ .int64 = r.age };
            return null;
        }
    }.get;

    try std.testing.expect(evalNode(pred, getter, &row));

    const row2 = Row{ .status = "inactive", .age = 25 };
    try std.testing.expect(!evalNode(pred, getter, &row2));
}

