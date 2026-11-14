const std = @import("std");
const Allocator = std.mem.Allocator;
const db_mod = @import("db.zig");
const Db = db_mod.Db;
const Stmt = db_mod.Stmt;

/// Prepared statement cache keyed by SQL query string (ARCH-009B §2.1).
/// Reuses compiled `sqlite3_stmt` instances across repeated writes/reads,
/// resetting and clearing bindings before each acquisition.
pub const StmtCache = struct {
    allocator: Allocator,
    db: *Db,
    entries: std.StringHashMapUnmanaged(Stmt) = .empty,

    pub fn init(allocator: Allocator, db: *Db) StmtCache {
        return .{
            .allocator = allocator,
            .db = db,
        };
    }

    pub fn deinit(self: *StmtCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn len(self: *const StmtCache) usize {
        return self.entries.count();
    }

    /// Returns a cached `Stmt` (reset + bindings cleared) or prepares and caches it.
    /// Caller must NOT call `deinit()` on the returned `*Stmt` — `StmtCache` owns it.
    pub fn acquire(self: *StmtCache, sql: []const u8) !*Stmt {
        if (self.entries.getPtr(sql)) |stmt| {
            stmt.resetAndClear();
            return stmt;
        }
        const owned_sql = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(owned_sql);

        var stmt = try self.db.prepare(owned_sql);
        errdefer stmt.deinit();

        try self.entries.put(self.allocator, owned_sql, stmt);
        return self.entries.getPtr(owned_sql).?;
    }
};

test "StmtCache: prepares once, resets and reuses across iterations" {
    const testing = std.testing;
    var db = try Db.openMemory(.{});
    defer db.close();

    try db.execZ("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT) STRICT;");

    var cache = StmtCache.init(testing.allocator, &db);
    defer cache.deinit();

    const insert_sql = "INSERT INTO t (id, name) VALUES (?1, ?2);";
    for (1..4) |i| {
        const stmt = try cache.acquire(insert_sql);
        try stmt.bindInt64(1, @intCast(i));
        try stmt.bindText(2, "item");
        try stmt.execStep();
    }
    try testing.expectEqual(@as(usize, 1), cache.len());

    var sel = try db.prepare("SELECT COUNT(*) FROM t;");
    defer sel.deinit();
    const row = (try sel.step()).?;
    try testing.expectEqual(@as(i64, 3), row.int64(0));
}
