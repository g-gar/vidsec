const std = @import("std");
const Allocator = std.mem.Allocator;

pub const YamlAstError = error{
    UnexpectedToken,
    InvalidIndentation,
    UnclosedQuote,
    UnclosedFlowCollection,
    DuplicateMapKey,
    ExpectedColonInMap,
    InvalidBlockScalar,
    ScalarTransformFailed,
    OutOfMemory,
};

pub const SourceLoc = struct {
    line: usize,
    column: usize,
};

pub const QuoteStyle = enum {
    plain,
    single,
    double,
    block_literal,
    block_folded,
};

pub const Scalar = struct {
    value: []const u8,
    quote_style: QuoteStyle = .plain,
};

pub const MapEntry = struct {
    key: []const u8,
    key_loc: SourceLoc,
    value: Node,
};

/// Generic, domain-agnostic YAML AST node.
pub const Node = struct {
    loc: SourceLoc,
    data: Data,

    pub const Data = union(enum) {
        scalar: Scalar,
        seq: []const Node,
        map: []const MapEntry,
    };

    /// Looks up a key in a `.map` node and returns its value `Node`, or `null`.
    pub fn get(self: Node, key: []const u8) ?Node {
        switch (self.data) {
            .map => |entries| {
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, key)) return entry.value;
                }
                return null;
            },
            else => return null,
        }
    }

    /// Returns the scalar string if the node is `.scalar`, or `null` otherwise.
    pub fn asScalar(self: Node) ?[]const u8 {
        return switch (self.data) {
            .scalar => |s| s.value,
            else => null,
        };
    }

    /// Returns the full `Scalar` (with quote style) if the node is `.scalar`, or `null` otherwise.
    pub fn asScalarInfo(self: Node) ?Scalar {
        return switch (self.data) {
            .scalar => |s| s,
            else => null,
        };
    }

    /// Returns the slice of entries if the node is `.map`, or `null` otherwise.
    pub fn asMap(self: Node) ?[]const MapEntry {
        return switch (self.data) {
            .map => |entries| entries,
            else => null,
        };
    }

    /// Returns the slice of elements if the node is `.seq`, or `null` otherwise.
    pub fn asSeq(self: Node) ?[]const Node {
        return switch (self.data) {
            .seq => |items| items,
            else => null,
        };
    }
};

/// Optional callback hook invoked on every parsed scalar value (e.g., for `.env` variable expansion).
pub const ScalarHook = struct {
    ctx: *const anyopaque,
    transformFn: *const fn (ctx: *const anyopaque, arena: Allocator, raw: []const u8) anyerror![]const u8,

    pub fn apply(self: ScalarHook, arena: Allocator, raw: []const u8) ![]const u8 {
        return self.transformFn(self.ctx, arena, raw);
    }
};

pub const AstOptions = struct {
    allow_duplicate_keys: bool = false,
    scalar_hook: ?ScalarHook = null,
};

const LineInfo = struct {
    line_num: usize, // 1-based
    indent: usize,
    content: []const u8, // Trimmed of trailing comments and whitespace
    raw_after_indent: []const u8, // Preserved for `|` and `>` block scalars
    is_empty: bool,
};

/// Parses a YAML string into an untyped `Node` tree allocated in `arena`.
pub fn parseAst(
    arena: Allocator,
    source: []const u8,
    options: AstOptions,
) anyerror!Node {
    var lines_list: std.ArrayListUnmanaged(LineInfo) = .empty;
    var raw_iter = std.mem.splitScalar(u8, source, '\n');
    var line_idx: usize = 0;

    while (raw_iter.next()) |raw_line| {
        line_idx += 1;
        const clean_cr = std.mem.trimEnd(u8, raw_line, "\r");
        var indent: usize = 0;
        while (indent < clean_cr.len and clean_cr[indent] == ' ') : (indent += 1) {}
        if (indent < clean_cr.len and clean_cr[indent] == '\t') {
            return error.InvalidIndentation;
        }

        const after_indent = clean_cr[indent..];
        const without_comment = stripComment(after_indent);
        const trimmed = std.mem.trimEnd(u8, without_comment, " \t");

        const is_empty = (trimmed.len == 0) or std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "...");
        try lines_list.append(arena, .{
            .line_num = line_idx,
            .indent = indent,
            .content = trimmed,
            .raw_after_indent = after_indent,
            .is_empty = is_empty,
        });
    }

    var parser = Parser{
        .arena = arena,
        .lines = lines_list.items,
        .idx = 0,
        .options = options,
    };

    parser.skipEmpty();
    if (parser.idx >= parser.lines.len) {
        return Node{
            .loc = .{ .line = 1, .column = 1 },
            .data = .{ .map = &.{} },
        };
    }

    const first_indent = parser.lines[parser.idx].indent;
    return parser.parseBlockNode(first_indent);
}

const Parser = struct {
    arena: Allocator,
    lines: []const LineInfo,
    idx: usize,
    options: AstOptions,

    fn skipEmpty(self: *Parser) void {
        while (self.idx < self.lines.len and self.lines[self.idx].is_empty) {
            self.idx += 1;
        }
    }

    fn parseBlockNode(self: *Parser, expected_indent: usize) anyerror!Node {
        self.skipEmpty();
        if (self.idx >= self.lines.len) {
            return Node{
                .loc = .{ .line = 1, .column = 1 },
                .data = .{ .map = &.{} },
            };
        }

        const line = self.lines[self.idx];
        if (line.indent < expected_indent) {
            return error.InvalidIndentation;
        }

        if (isSeqItemLine(line.content)) {
            return self.parseBlockSeq(line.indent);
        } else if (line.content[0] == '{' or line.content[0] == '[') {
            self.idx += 1;
            return self.parseFlowValue(line.content, .{
                .line = line.line_num,
                .column = line.indent + 1,
            });
        } else {
            return self.parseBlockMap(line.indent);
        }
    }

    fn parseBlockSeq(self: *Parser, seq_indent: usize) anyerror!Node {
        const start_loc = SourceLoc{
            .line = self.lines[self.idx].line_num,
            .column = seq_indent + 1,
        };
        var items: std.ArrayListUnmanaged(Node) = .empty;

        while (true) {
            self.skipEmpty();
            if (self.idx >= self.lines.len) break;
            const line = self.lines[self.idx];
            if (line.indent < seq_indent) break;
            if (line.indent > seq_indent) return error.InvalidIndentation;
            if (!isSeqItemLine(line.content)) break;

            const item_loc = SourceLoc{
                .line = line.line_num,
                .column = line.indent + 1,
            };

            const after_dash_raw = if (line.content.len > 1) line.content[1..] else "";
            const after_dash_spaces = countLeadingSpaces(after_dash_raw);
            const rest = std.mem.trimStart(u8, after_dash_raw, " ");
            const item_content_indent = line.indent + 1 + after_dash_spaces;

            self.idx += 1;

            if (rest.len == 0) {
                self.skipEmpty();
                if (self.idx >= self.lines.len or self.lines[self.idx].indent <= seq_indent) {
                    try items.append(self.arena, .{
                        .loc = item_loc,
                        .data = .{ .scalar = .{ .value = "", .quote_style = .plain } },
                    });
                } else {
                    const child = try self.parseBlockNode(self.lines[self.idx].indent);
                    try items.append(self.arena, child);
                }
            } else if (rest[0] == '{' or rest[0] == '[') {
                const flow_node = try self.parseFlowValue(rest, item_loc);
                try items.append(self.arena, flow_node);
            } else if (findKeyValueColon(rest)) |colon_pos| {
                var entries: std.ArrayListUnmanaged(MapEntry) = .empty;
                try self.parseSingleMapEntryInto(
                    &entries,
                    rest,
                    colon_pos,
                    line.line_num,
                    item_content_indent,
                    item_content_indent,
                );
                try self.parseRemainingBlockMapEntries(&entries, item_content_indent);
                try items.append(self.arena, .{
                    .loc = item_loc,
                    .data = .{ .map = try entries.toOwnedSlice(self.arena) },
                });
            } else {
                const scalar = try self.parseScalarText(rest, item_loc);
                try items.append(self.arena, .{
                    .loc = item_loc,
                    .data = .{ .scalar = scalar },
                });
            }
        }

        return Node{
            .loc = start_loc,
            .data = .{ .seq = try items.toOwnedSlice(self.arena) },
        };
    }

    fn parseBlockMap(self: *Parser, map_indent: usize) anyerror!Node {
        const start_loc = SourceLoc{
            .line = self.lines[self.idx].line_num,
            .column = map_indent + 1,
        };
        var entries: std.ArrayListUnmanaged(MapEntry) = .empty;
        try self.parseRemainingBlockMapEntries(&entries, map_indent);
        return Node{
            .loc = start_loc,
            .data = .{ .map = try entries.toOwnedSlice(self.arena) },
        };
    }

    fn parseRemainingBlockMapEntries(
        self: *Parser,
        entries: *std.ArrayListUnmanaged(MapEntry),
        map_indent: usize,
    ) anyerror!void {
        while (true) {
            self.skipEmpty();
            if (self.idx >= self.lines.len) break;
            const line = self.lines[self.idx];
            if (line.indent < map_indent) break;
            if (line.indent > map_indent) return error.InvalidIndentation;
            if (isSeqItemLine(line.content)) break;

            const colon_pos = findKeyValueColon(line.content) orelse return error.ExpectedColonInMap;
            self.idx += 1;
            try self.parseSingleMapEntryInto(
                entries,
                line.content,
                colon_pos,
                line.line_num,
                line.indent,
                map_indent,
            );
        }
    }

    fn parseSingleMapEntryInto(
        self: *Parser,
        entries: *std.ArrayListUnmanaged(MapEntry),
        content: []const u8,
        colon_pos: usize,
        line_num: usize,
        key_indent: usize,
        parent_map_indent: usize,
    ) anyerror!void {
        const raw_key = std.mem.trim(u8, content[0..colon_pos], " \t");
        if (raw_key.len == 0) return error.ExpectedColonInMap;
        const key_loc = SourceLoc{ .line = line_num, .column = key_indent + 1 };
        const key_scalar = try self.parseKeyText(raw_key, key_loc);

        if (!self.options.allow_duplicate_keys) {
            for (entries.items) |existing| {
                if (std.mem.eql(u8, existing.key, key_scalar)) {
                    return error.DuplicateMapKey;
                }
            }
        }

        const val_part = std.mem.trim(u8, content[colon_pos + 1 ..], " \t");
        const val_loc = SourceLoc{
            .line = line_num,
            .column = key_indent + colon_pos + 2,
        };

        const val_node: Node = blk: {
            if (val_part.len == 0) {
                self.skipEmpty();
                if (self.idx >= self.lines.len or self.lines[self.idx].indent < parent_map_indent) {
                    break :blk Node{
                        .loc = val_loc,
                        .data = .{ .scalar = .{ .value = "", .quote_style = .plain } },
                    };
                }
                const next_line = self.lines[self.idx];
                if (next_line.indent == parent_map_indent) {
                    if (isSeqItemLine(next_line.content)) {
                        break :blk try self.parseBlockSeq(next_line.indent);
                    }
                    break :blk Node{
                        .loc = val_loc,
                        .data = .{ .scalar = .{ .value = "", .quote_style = .plain } },
                    };
                }
                break :blk try self.parseBlockNode(next_line.indent);
            } else if (std.mem.eql(u8, val_part, "|") or std.mem.eql(u8, val_part, "|-") or
                std.mem.eql(u8, val_part, ">") or std.mem.eql(u8, val_part, ">-"))
            {
                const folded = val_part[0] == '>';
                break :blk try self.parseBlockScalar(parent_map_indent, folded, val_loc);
            } else if (val_part[0] == '{' or val_part[0] == '[') {
                break :blk try self.parseFlowValue(val_part, val_loc);
            } else {
                const scalar = try self.parseScalarText(val_part, val_loc);
                break :blk Node{
                    .loc = val_loc,
                    .data = .{ .scalar = scalar },
                };
            }
        };

        try entries.append(self.arena, .{
            .key = key_scalar,
            .key_loc = key_loc,
            .value = val_node,
        });
    }

    fn parseBlockScalar(
        self: *Parser,
        parent_indent: usize,
        folded: bool,
        loc: SourceLoc,
    ) anyerror!Node {
        self.skipEmpty();
        if (self.idx >= self.lines.len or self.lines[self.idx].indent <= parent_indent) {
            return Node{
                .loc = loc,
                .data = .{
                    .scalar = .{
                        .value = "",
                        .quote_style = if (folded) .block_folded else .block_literal,
                    },
                },
            };
        }

        const block_indent = self.lines[self.idx].indent;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var first = true;

        while (self.idx < self.lines.len) {
            const line = self.lines[self.idx];
            if (line.is_empty) {
                var lookahead = self.idx + 1;
                while (lookahead < self.lines.len and self.lines[lookahead].is_empty) : (lookahead += 1) {}
                if (lookahead < self.lines.len and self.lines[lookahead].indent >= block_indent) {
                    try buf.append(self.arena, '\n');
                    self.idx += 1;
                    continue;
                } else {
                    break;
                }
            }

            if (line.indent < block_indent) break;

            if (!first) {
                try buf.append(self.arena, if (folded) ' ' else '\n');
            }
            first = false;

            const extra_spaces = line.indent - block_indent;
            try buf.appendNTimes(self.arena, ' ', extra_spaces);
            try buf.appendSlice(self.arena, std.mem.trimEnd(u8, line.raw_after_indent, " \t"));
            self.idx += 1;
        }

        const raw_text = try buf.toOwnedSlice(self.arena);
        const transformed = if (self.options.scalar_hook) |hook|
            try hook.apply(self.arena, raw_text)
        else
            raw_text;

        return Node{
            .loc = loc,
            .data = .{
                .scalar = .{
                    .value = transformed,
                    .quote_style = if (folded) .block_folded else .block_literal,
                },
            },
        };
    }

    fn parseFlowValue(self: *Parser, text: []const u8, loc: SourceLoc) anyerror!Node {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) {
            return Node{
                .loc = loc,
                .data = .{ .scalar = .{ .value = "", .quote_style = .plain } },
            };
        }

        if (trimmed[0] == '{') {
            if (trimmed[trimmed.len - 1] != '}') return error.UnclosedFlowCollection;
            const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
            var entries: std.ArrayListUnmanaged(MapEntry) = .empty;
            if (inner.len > 0) {
                const parts = try splitFlowItems(self.arena, inner);
                for (parts.items) |part| {
                    const item_str = std.mem.trim(u8, part, " \t");
                    if (item_str.len == 0) continue;
                    const colon_pos = findKeyValueColon(item_str) orelse return error.ExpectedColonInMap;
                    const raw_k = std.mem.trim(u8, item_str[0..colon_pos], " \t");
                    const raw_v = std.mem.trim(u8, item_str[colon_pos + 1 ..], " \t");
                    if (raw_k.len == 0 or raw_v.len == 0) return error.ExpectedColonInMap;

                    const k = try self.parseKeyText(raw_k, loc);
                    if (!self.options.allow_duplicate_keys) {
                        for (entries.items) |existing| {
                            if (std.mem.eql(u8, existing.key, k)) return error.DuplicateMapKey;
                        }
                    }
                    const v_node = try self.parseFlowValue(raw_v, loc);
                    try entries.append(self.arena, .{
                        .key = k,
                        .key_loc = loc,
                        .value = v_node,
                    });
                }
            }
            return Node{
                .loc = loc,
                .data = .{ .map = try entries.toOwnedSlice(self.arena) },
            };
        } else if (trimmed[0] == '[') {
            if (trimmed[trimmed.len - 1] != ']') return error.UnclosedFlowCollection;
            const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
            var items: std.ArrayListUnmanaged(Node) = .empty;
            if (inner.len > 0) {
                const parts = try splitFlowItems(self.arena, inner);
                for (parts.items) |part| {
                    const item_str = std.mem.trim(u8, part, " \t");
                    if (item_str.len == 0) continue;
                    const item_node = try self.parseFlowValue(item_str, loc);
                    try items.append(self.arena, item_node);
                }
            }
            return Node{
                .loc = loc,
                .data = .{ .seq = try items.toOwnedSlice(self.arena) },
            };
        } else {
            const scalar = try self.parseScalarText(trimmed, loc);
            return Node{
                .loc = loc,
                .data = .{ .scalar = scalar },
            };
        }
    }

    fn parseKeyText(self: *Parser, raw: []const u8, loc: SourceLoc) anyerror![]const u8 {
        _ = loc;
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')))
        {
            return self.arena.dupe(u8, trimmed[1 .. trimmed.len - 1]);
        }
        return self.arena.dupe(u8, trimmed);
    }

    fn parseScalarText(self: *Parser, raw: []const u8, loc: SourceLoc) anyerror!Scalar {
        _ = loc;
        const trimmed = std.mem.trim(u8, raw, " \t");
        var style: QuoteStyle = .plain;
        var unquoted: []const u8 = trimmed;

        if (trimmed.len > 0 and (trimmed[0] == '"' or trimmed[0] == '\'')) {
            const q = trimmed[0];
            if (trimmed.len < 2 or trimmed[trimmed.len - 1] != q) {
                return error.UnclosedQuote;
            }
            style = if (q == '"') .double else .single;
            const inner = trimmed[1 .. trimmed.len - 1];
            if (q == '"') {
                unquoted = try unescapeDoubleQuoted(self.arena, inner);
            } else {
                unquoted = try unescapeSingleQuoted(self.arena, inner);
            }
        } else {
            unquoted = try self.arena.dupe(u8, trimmed);
        }

        const final_val = if (self.options.scalar_hook) |hook|
            try hook.apply(self.arena, unquoted)
        else
            unquoted;

        return Scalar{
            .value = final_val,
            .quote_style = style,
        };
    }
};

fn isSeqItemLine(content: []const u8) bool {
    if (content.len == 0 or content[0] != '-') return false;
    if (content.len == 1) return true;
    return content[1] == ' ';
}

fn countLeadingSpaces(s: []const u8) usize {
    var count: usize = 0;
    while (count < s.len and s[count] == ' ') : (count += 1) {}
    return count;
}

fn stripComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\' and in_double) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
        } else if (c == '"' and !in_single) {
            in_double = !in_double;
        } else if (c == '#' and !in_single and !in_double) {
            if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t') {
                return line[0..i];
            }
        }
    }
    return line;
}

fn findKeyValueColon(s: []const u8) ?usize {
    var in_single = false;
    var in_double = false;
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
    var i: usize = 0;

    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\' and in_double) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
        } else if (c == '"' and !in_single) {
            in_double = !in_double;
        } else if (!in_single and !in_double) {
            if (c == '{') {
                brace_depth += 1;
            } else if (c == '}' and brace_depth > 0) {
                brace_depth -= 1;
            } else if (c == '[') {
                bracket_depth += 1;
            } else if (c == ']' and bracket_depth > 0) {
                bracket_depth -= 1;
            } else if (c == ':' and brace_depth == 0 and bracket_depth == 0) {
                if (i + 1 == s.len or s[i + 1] == ' ' or s[i + 1] == '\t') {
                    return i;
                }
            }
        }
    }
    return null;
}

fn splitFlowItems(arena: Allocator, inner: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    var in_single = false;
    var in_double = false;
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;

    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c == '\\' and in_double) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
        } else if (c == '"' and !in_single) {
            in_double = !in_double;
        } else if (!in_single and !in_double) {
            if (c == '{') {
                brace_depth += 1;
            } else if (c == '}') {
                if (brace_depth == 0) return error.UnclosedFlowCollection;
                brace_depth -= 1;
            } else if (c == '[') {
                bracket_depth += 1;
            } else if (c == ']') {
                if (bracket_depth == 0) return error.UnclosedFlowCollection;
                bracket_depth -= 1;
            } else if (c == ',' and brace_depth == 0 and bracket_depth == 0) {
                try result.append(arena, inner[start..i]);
                start = i + 1;
            }
        }
    }

    if (in_single or in_double) return error.UnclosedQuote;
    if (brace_depth != 0 or bracket_depth != 0) return error.UnclosedFlowCollection;
    try result.append(arena, inner[start..]);
    return result;
}

fn unescapeDoubleQuoted(arena: Allocator, inner: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
        return arena.dupe(u8, inner);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
            switch (inner[i]) {
                'n' => try out.append(arena, '\n'),
                'r' => try out.append(arena, '\r'),
                't' => try out.append(arena, '\t'),
                '"' => try out.append(arena, '"'),
                '\\' => try out.append(arena, '\\'),
                else => {
                    try out.append(arena, '\\');
                    try out.append(arena, inner[i]);
                },
            }
        } else {
            try out.append(arena, inner[i]);
        }
    }
    return out.toOwnedSlice(arena);
}

fn unescapeSingleQuoted(arena: Allocator, inner: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, inner, "''") == null) {
        return arena.dupe(u8, inner);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\'' and i + 1 < inner.len and inner[i + 1] == '\'') {
            try out.append(arena, '\'');
            i += 1;
        } else {
            try out.append(arena, inner[i]);
        }
    }
    return out.toOwnedSlice(arena);
}
