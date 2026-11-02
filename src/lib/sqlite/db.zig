const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SqliteError = error{
    SqliteError,
    Internal,
    PermissionDenied,
    Abort,
    Busy,
    Locked,
    OutOfMemory,
    ReadOnly,
    Interrupt,
    IoError,
    Corrupt,
    NotFound,
    Full,
    CannotOpen,
    Protocol,
    SchemaChanged,
    TooBig,
    ConstraintViolation,
    DatatypeMismatch,
    Misuse,
    AuthDenied,
    RangeError,
    NotADatabase,
    StatementNotReadOnly,
    UnknownParameterName,
    NullPointerInText,
};

/// Dynamic typed value with 1:1 correspondence to SQLite3 storage classes (`NULL`, `INTEGER`, `REAL`, `TEXT`, `BLOB`).
pub const Value = union(enum) {
    null_val,
    int64: i64,
    float64: f64,
    boolean: bool,
    text: []const u8,
    blob: []const u8,

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .null_val => try writer.writeAll("NULL"),
            .int64 => |v| try writer.print("{d}", .{v}),
            .float64 => |v| try writer.print("{d}", .{v}),
            .boolean => |v| try writer.writeAll(if (v) "1" else "0"),
            .text => |v| try writer.print("'{s}'", .{v}),
            .blob => |v| try writer.print("<blob:{d}B>", .{v.len}),
        }
    }
};

pub const JournalMode = enum {
    memory,
    wal,
    delete,
    truncate,
    persist,
    off,
};

pub const SynchronousMode = enum {
    off,
    normal,
    full,
    extra,
};

pub const OpenOptions = struct {
    read_only: bool = false,
    create: bool = true,
    full_mutex: bool = false,
    busy_timeout_ms: u32 = 5000,
    foreign_keys: bool = true,
    journal_mode: ?JournalMode = null,
    synchronous: ?SynchronousMode = null,
};

/// Idiomatic Zig wrapper around `*c.sqlite3`.
pub const Db = struct {
    handle: *c.sqlite3,

    /// Opens an in-memory SQLite3 database (`:memory:`).
    pub fn openMemory(options: OpenOptions) SqliteError!Db {
        return openZ(":memory:", options);
    }

    /// Opens a file-backed SQLite3 database (accepts a non-sentinel slice by copying to stack/temp buffer).
    pub fn openFile(allocator: Allocator, path: []const u8, options: OpenOptions) SqliteError!Db {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        return openZ(path_z, options);
    }

    /// Opens a SQLite3 database from a null-terminated path (`:memory:` or file path).
    pub fn openZ(path_z: [:0]const u8, options: OpenOptions) SqliteError!Db {
        var flags: c_int = if (options.read_only)
            c.SQLITE_OPEN_READONLY
        else
            c.SQLITE_OPEN_READWRITE | (if (options.create) c.SQLITE_OPEN_CREATE else 0);

        if (options.full_mutex) {
            flags |= c.SQLITE_OPEN_FULLMUTEX;
        } else {
            flags |= c.SQLITE_OPEN_NOMUTEX;
        }

        var raw_db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path_z.ptr, &raw_db, flags, null);
        if (rc != c.SQLITE_OK) {
            if (raw_db) |h| {
                _ = c.sqlite3_close_v2(h);
            }
            return mapSqliteCode(rc);
        }

        var db = Db{ .handle = raw_db.? };
        errdefer db.close();

        try db.setBusyTimeout(options.busy_timeout_ms);
        if (options.foreign_keys) {
            try db.setForeignKeys(true);
        }
        if (options.journal_mode) |jm| {
            try db.setJournalMode(jm);
        }
        if (options.synchronous) |sync_mode| {
            try db.setSynchronous(sync_mode);
        }

        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close_v2(self.handle);
    }

    pub fn lastErrorMessage(self: *const Db) []const u8 {
        const ptr = c.sqlite3_errmsg(self.handle);
        if (ptr == null) return "unknown sqlite error";
        return std.mem.span(ptr);
    }

    pub fn lastExtendedErrorCode(self: *const Db) c_int {
        return c.sqlite3_extended_errcode(self.handle);
    }

    pub fn changes(self: *const Db) usize {
        const n = c.sqlite3_changes64(self.handle);
        return if (n < 0) 0 else @intCast(n);
    }

    pub fn lastInsertRowId(self: *const Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn setBusyTimeout(self: *Db, timeout_ms: u32) SqliteError!void {
        const rc = c.sqlite3_busy_timeout(self.handle, @intCast(timeout_ms));
        if (rc != c.SQLITE_OK) return mapSqliteCode(rc);
    }

    pub fn setForeignKeys(self: *Db, enabled: bool) SqliteError!void {
        try self.execZ(if (enabled) "PRAGMA foreign_keys = ON;" else "PRAGMA foreign_keys = OFF;");
    }

    pub fn setJournalMode(self: *Db, mode: JournalMode) SqliteError!void {
        const sql: [:0]const u8 = switch (mode) {
            .memory => "PRAGMA journal_mode = MEMORY;",
            .wal => "PRAGMA journal_mode = WAL;",
            .delete => "PRAGMA journal_mode = DELETE;",
            .truncate => "PRAGMA journal_mode = TRUNCATE;",
            .persist => "PRAGMA journal_mode = PERSIST;",
            .off => "PRAGMA journal_mode = OFF;",
        };
        try self.execZ(sql);
    }

    pub fn setSynchronous(self: *Db, mode: SynchronousMode) SqliteError!void {
        const sql: [:0]const u8 = switch (mode) {
            .off => "PRAGMA synchronous = OFF;",
            .normal => "PRAGMA synchronous = NORMAL;",
            .full => "PRAGMA synchronous = FULL;",
            .extra => "PRAGMA synchronous = EXTRA;",
        };
        try self.execZ(sql);
    }

    /// Executes one or more semicolon-separated SQL statements from a null-terminated string.
    pub fn execZ(self: *Db, sql_z: [:0]const u8) SqliteError!void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql_z.ptr, null, null, &err_msg);
        if (err_msg != null) {
            c.sqlite3_free(err_msg);
        }
        if (rc != c.SQLITE_OK) return mapSqliteCode(rc);
    }

    /// Executes one or more semicolon-separated SQL statements from a regular Zig slice
    /// without requiring null-termination (iterates via `sqlite3_prepare_v2` tail pointer).
    pub fn exec(self: *Db, sql: []const u8) SqliteError!void {
        var remaining = sql;
        while (remaining.len > 0) {
            const trimmed = std.mem.trim(u8, remaining, " \t\r\n");
            if (trimmed.len == 0) break;

            var raw_stmt: ?*c.sqlite3_stmt = null;
            var tail_ptr: [*c]const u8 = null;
            const rc = c.sqlite3_prepare_v2(
                self.handle,
                trimmed.ptr,
                @intCast(trimmed.len),
                &raw_stmt,
                &tail_ptr,
            );
            if (rc != c.SQLITE_OK) return mapSqliteCode(rc);

            if (raw_stmt) |stmt_handle| {
                var stmt = Stmt{ .handle = stmt_handle, .db_handle = self.handle };
                defer stmt.deinit();
                while (try stmt.step() != null) {}
            }

            if (tail_ptr == null) break;
            const consumed = @intFromPtr(tail_ptr) - @intFromPtr(trimmed.ptr);
            if (consumed >= trimmed.len) break;
            remaining = trimmed[consumed..];
        }
    }

    /// Compiles a single SQL statement from a Zig slice (`[]const u8`).
    pub fn prepare(self: *Db, sql: []const u8) SqliteError!Stmt {
        var raw_stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            sql.ptr,
            @intCast(sql.len),
            &raw_stmt,
            null,
        );
        if (rc != c.SQLITE_OK) return mapSqliteCode(rc);
        const stmt_handle = raw_stmt orelse return error.Misuse;
        return Stmt{
            .handle = stmt_handle,
            .db_handle = self.handle,
        };
    }

    /// Compiles a SQL statement and enforces at the C-API level (`sqlite3_stmt_readonly`)
    /// that it cannot mutate the database in any way.
    pub fn prepareReadOnly(self: *Db, sql: []const u8) SqliteError!Stmt {
        var stmt = try self.prepare(sql);
        errdefer stmt.deinit();
        if (!stmt.isReadOnly()) {
            return error.StatementNotReadOnly;
        }
        return stmt;
    }

    /// Opens a nested transaction savepoint (`SAVEPOINT "<name>";`).
    pub fn savepoint(self: *Db, name: []const u8) SqliteError!Savepoint {
        var buf: [256]u8 = undefined;
        const sql = formatSavepointCmd(&buf, "SAVEPOINT", name) catch return error.TooBig;
        try self.exec(sql);
        return Savepoint{
            .db = self,
            .name = name,
            .active = true,
        };
    }
};

/// Scoped transaction savepoint with `.release()` and `.rollback()`.
pub const Savepoint = struct {
    db: *Db,
    name: []const u8,
    active: bool,

    /// Commits (`RELEASE SAVEPOINT "<name>";`) the savepoint.
    pub fn release(self: *Savepoint) SqliteError!void {
        if (!self.active) return;
        var buf: [256]u8 = undefined;
        const sql = formatSavepointCmd(&buf, "RELEASE SAVEPOINT", self.name) catch return error.TooBig;
        try self.db.exec(sql);
        self.active = false;
    }

    /// Rolls back (`ROLLBACK TO SAVEPOINT "<name>"; RELEASE SAVEPOINT "<name>";`) the savepoint.
    pub fn rollback(self: *Savepoint) void {
        if (!self.active) return;
        var buf: [256]u8 = undefined;
        if (formatSavepointCmd(&buf, "ROLLBACK TO SAVEPOINT", self.name)) |rb_sql| {
            self.db.exec(rb_sql) catch {};
        } else |_| {}
        if (formatSavepointCmd(&buf, "RELEASE SAVEPOINT", self.name)) |rel_sql| {
            self.db.exec(rel_sql) catch {};
        } else |_| {}
        self.active = false;
    }
};

fn formatSavepointCmd(buf: []u8, prefix: []const u8, name: []const u8) ![]const u8 {
    for (name) |ch| {
        if (ch == '"' or ch == 0 or ch == ';') return error.InvalidArgument;
    }
    return std.fmt.bufPrint(buf, "{s} \"{s}\";", .{ prefix, name });
}

const sqlite_transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

/// Idiomatic Zig wrapper around `*c.sqlite3_stmt`.
pub const Stmt = struct {
    handle: *c.sqlite3_stmt,
    db_handle: *c.sqlite3,

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    /// Resets the statement execution cursor and optionally clears bound parameters.
    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.handle);
    }

    pub fn resetAndClear(self: *Stmt) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    /// Returns `true` if and only if the prepared statement makes no direct changes to database files
    /// (`sqlite3_stmt_readonly(stmt) != 0`).
    pub fn isReadOnly(self: *const Stmt) bool {
        return c.sqlite3_stmt_readonly(self.handle) != 0;
    }

    /// Number of columns in the result set of this prepared statement.
    pub fn columnCount(self: *const Stmt) usize {
        const n = c.sqlite3_column_count(self.handle);
        return if (n < 0) 0 else @intCast(n);
    }

    /// Returns the name assigned to result column `col_idx` (0-based), or `AS` alias if present.
    pub fn columnName(self: *const Stmt, col_idx: usize) []const u8 {
        const ptr = c.sqlite3_column_name(self.handle, @intCast(col_idx));
        if (ptr == null) return "";
        return std.mem.span(ptr);
    }

    /// Returns the 1-based parameter index for a named parameter (e.g. `":id"`, `"@id"`, `"$id"`).
    pub fn paramIndex(self: *const Stmt, name_z: [:0]const u8) SqliteError!usize {
        const idx = c.sqlite3_bind_parameter_index(self.handle, name_z.ptr);
        if (idx <= 0) return error.UnknownParameterName;
        return @intCast(idx);
    }

    pub fn bindNull(self: *Stmt, param_idx_1based: usize) SqliteError!void {
        const rc = c.sqlite3_bind_null(self.handle, @intCast(param_idx_1based));
        if (rc != c.SQLITE_OK) return mapSqliteCode(rc);
    }

    pub fn bindInt64(self: *Stmt, param_idx_1based: usize, val: i64) SqliteError!void {
        const rc = c.sqlite3_bind_int64(self.handle, @intCast(param_idx_1based), val);
        if (rc != c.SQLITE_OK) return mapSqliteCode(rc);
    }

    pub fn bindFloat64(self: *Stmt, param_idx_1based: usize, val: f64) SqliteError!void {
        const rc = c.sqlite3_bind_double(self.handle, @intCast(param_idx_1based), val);
        if (rc != c.SQLITE_OK) return mapSqliteCode(rc);
    }

    pub fn bindBool(self: *Stmt, param_idx_1based: usize, val: bool) SqliteError!void {
        return self.bindInt64(param_idx_1based, if (val) 1 else 0);
    }

    pub fn bindText(self: *Stmt, param_idx_1based: usize, text: []const u8) SqliteError!void {
        const ptr: [*c]const u8 = if (text.len > 0) text.ptr else "";
        const rc = c.sqlite3_bind_text(
            self.handle,
            @intCast(param_idx_1based),
            ptr,
            @intCast(text.len),
            sqlite_transient,
        );
        if (rc != c.SQLITE_OK) return mapSqliteCode(rc);
    }

    pub fn bindBlob(self: *Stmt, param_idx_1based: usize, bytes: []const u8) SqliteError!void {
        const ptr: ?*const anyopaque = if (bytes.len > 0) @ptrCast(bytes.ptr) else null;
        const rc = c.sqlite3_bind_blob(
            self.handle,
            @intCast(param_idx_1based),
            ptr,
            @intCast(bytes.len),
            sqlite_transient,
        );
        if (rc != c.SQLITE_OK) return mapSqliteCode(rc);
    }

    /// Binds a dynamic `Value` at 1-based parameter position `param_idx_1based`.
    pub fn bindValue(self: *Stmt, param_idx_1based: usize, val: Value) SqliteError!void {
        return switch (val) {
            .null_val => self.bindNull(param_idx_1based),
            .int64 => |v| self.bindInt64(param_idx_1based, v),
            .float64 => |v| self.bindFloat64(param_idx_1based, v),
            .boolean => |v| self.bindBool(param_idx_1based, v),
            .text => |v| self.bindText(param_idx_1based, v),
            .blob => |v| self.bindBlob(param_idx_1based, v),
        };
    }

    /// Binds a slice of `Value` items sequentially (`?1 .. ?N`).
    pub fn bindAll(self: *Stmt, values: []const Value) SqliteError!void {
        for (values, 1..) |v, idx| {
            try self.bindValue(idx, v);
        }
    }

    /// Advances the statement by one step:
    /// - Returns `Row` when `sqlite3_step` yields `SQLITE_ROW`.
    /// - Returns `null` when `sqlite3_step` reaches `SQLITE_DONE`.
    pub fn step(self: *Stmt) SqliteError!?Row {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_ROW => Row{ .stmt = self.handle },
            c.SQLITE_DONE => null,
            else => mapSqliteCode(rc),
        };
    }

    /// Executes a statement expected to produce no rows (e.g. `INSERT`, `UPDATE`, `DELETE`).
    pub fn execStep(self: *Stmt) SqliteError!void {
        while (try self.step() != null) {}
    }
};

/// View over the current row of a stepped `Stmt`.
/// Slice views (`text`, `blob`) are valid until the next `step()`, `reset()`, or `deinit()` call.
pub const Row = struct {
    stmt: *c.sqlite3_stmt,

    pub fn columnCount(self: Row) usize {
        const n = c.sqlite3_column_count(self.stmt);
        return if (n < 0) 0 else @intCast(n);
    }

    pub fn columnName(self: Row, col_idx: usize) []const u8 {
        const ptr = c.sqlite3_column_name(self.stmt, @intCast(col_idx));
        if (ptr == null) return "";
        return std.mem.span(ptr);
    }

    pub fn isNull(self: Row, col_idx: usize) bool {
        return c.sqlite3_column_type(self.stmt, @intCast(col_idx)) == c.SQLITE_NULL;
    }

    pub fn int64(self: Row, col_idx: usize) i64 {
        return c.sqlite3_column_int64(self.stmt, @intCast(col_idx));
    }

    pub fn float64(self: Row, col_idx: usize) f64 {
        return c.sqlite3_column_double(self.stmt, @intCast(col_idx));
    }

    pub fn boolean(self: Row, col_idx: usize) bool {
        return self.int64(col_idx) != 0;
    }

    pub fn text(self: Row, col_idx: usize) []const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, @intCast(col_idx));
        if (ptr == null) return "";
        const len_c = c.sqlite3_column_bytes(self.stmt, @intCast(col_idx));
        if (len_c <= 0) return "";
        return ptr[0..@intCast(len_c)];
    }

    pub fn blob(self: Row, col_idx: usize) []const u8 {
        const raw_ptr = c.sqlite3_column_blob(self.stmt, @intCast(col_idx));
        if (raw_ptr == null) return &.{};
        const len_c = c.sqlite3_column_bytes(self.stmt, @intCast(col_idx));
        if (len_c <= 0) return &.{};
        const byte_ptr: [*]const u8 = @ptrCast(raw_ptr);
        return byte_ptr[0..@intCast(len_c)];
    }

    /// Reads column `col_idx` (0-based) dynamically according to its runtime SQLite storage class.
    pub fn value(self: Row, col_idx: usize) Value {
        const col_type = c.sqlite3_column_type(self.stmt, @intCast(col_idx));
        return switch (col_type) {
            c.SQLITE_NULL => .null_val,
            c.SQLITE_INTEGER => .{ .int64 = self.int64(col_idx) },
            c.SQLITE_FLOAT => .{ .float64 = self.float64(col_idx) },
            c.SQLITE_TEXT => .{ .text = self.text(col_idx) },
            c.SQLITE_BLOB => .{ .blob = self.blob(col_idx) },
            else => .null_val,
        };
    }
};

pub fn mapSqliteCode(rc: c_int) SqliteError {
    return switch (rc & 0xff) {
        c.SQLITE_INTERNAL => error.Internal,
        c.SQLITE_PERM => error.PermissionDenied,
        c.SQLITE_ABORT => error.Abort,
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_IOERR => error.IoError,
        c.SQLITE_CORRUPT => error.Corrupt,
        c.SQLITE_NOTFOUND => error.NotFound,
        c.SQLITE_FULL => error.Full,
        c.SQLITE_CANTOPEN => error.CannotOpen,
        c.SQLITE_PROTOCOL => error.Protocol,
        c.SQLITE_SCHEMA => error.SchemaChanged,
        c.SQLITE_TOOBIG => error.TooBig,
        c.SQLITE_CONSTRAINT => error.ConstraintViolation,
        c.SQLITE_MISMATCH => error.DatatypeMismatch,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_AUTH => error.AuthDenied,
        c.SQLITE_RANGE => error.RangeError,
        c.SQLITE_NOTADB => error.NotADatabase,
        else => error.SqliteError,
    };
}
