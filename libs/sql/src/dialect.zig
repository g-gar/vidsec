const std = @import("std");

/// Positional parameter placeholder syntax for a SQL dialect.
pub const PlaceholderStyle = union(enum) {
    /// Unindexed placeholder token emitted verbatim (e.g. "?").
    anonymous: []const u8,
    /// 1-based indexed placeholder with prefix (e.g. "?" -> "?1", "$" -> "$1").
    indexed: []const u8,
};

/// Syntax used when `InsertQuery.or_ignore` is true and no explicit `on_conflict` is set.
pub const InsertIgnoreStyle = enum {
    /// Emits `INSERT OR IGNORE INTO ...`
    or_ignore_prefix,
    /// Emits `INSERT IGNORE INTO ...`
    ignore_prefix,
    /// Emits `INSERT INTO ... ON CONFLICT DO NOTHING`
    on_conflict_do_nothing_suffix,
};

/// Syntax used for `InsertQuery.on_conflict` upserts.
pub const UpsertStyle = enum {
    /// Emits `ON CONFLICT(<cols>) DO NOTHING` / `DO UPDATE SET <col> = excluded.<col>`
    on_conflict_excluded,
    /// Emits `ON DUPLICATE KEY UPDATE <col> = VALUES(<col>)`
    on_duplicate_key_values,
};

/// Engine-agnostic SQL syntax descriptor.
/// Concrete database adapters (e.g. `libs/sqlite`) supply a `Dialect` configuration
/// describing their syntax capabilities without `libs/sql` knowing about specific engines.
pub const Dialect = struct {
    ident_quote: u8 = '"',
    placeholder: PlaceholderStyle = .{ .anonymous = "?" },
    /// When `OFFSET` is specified without `LIMIT`, some engines require an explicit
    /// `LIMIT <n>` before `OFFSET` (e.g. `-1`). `null` emits `OFFSET <n>` directly.
    offset_only_limit: ?i64 = null,
    insert_ignore: InsertIgnoreStyle = .on_conflict_do_nothing_suffix,
    upsert: UpsertStyle = .on_conflict_excluded,

    /// Default ANSI-like SQL dialect configuration.
    pub const ansi: Dialect = .{};

    pub fn identQuote(self: Dialect) u8 {
        return self.ident_quote;
    }

    pub fn writePlaceholder(
        self: Dialect,
        buf: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
        index_1based: usize,
    ) !void {
        switch (self.placeholder) {
            .anonymous => |token| try buf.appendSlice(allocator, token),
            .indexed => |prefix| {
                var tmp: [24]u8 = undefined;
                const num = try std.fmt.bufPrint(&tmp, "{d}", .{index_1based});
                try buf.appendSlice(allocator, prefix);
                try buf.appendSlice(allocator, num);
            },
        }
    }
};
