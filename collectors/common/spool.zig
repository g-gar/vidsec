const std = @import("std");
const Allocator = std.mem.Allocator;
const JobEnvelope = @import("envelope.zig").JobEnvelope;

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
    @cInclude("dirent.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});

/// Persistent crash-safe FIFO queue backed by local disk storage.
/// Used by collectors for store-and-forward resilience when Flowdata is down.
pub const SpoolQueue = struct {
    allocator: Allocator,
    spool_dir: []const u8,

    pub fn init(allocator: Allocator, spool_dir: []const u8) !SpoolQueue {
        const owned_dir = try allocator.dupe(u8, spool_dir);
        errdefer allocator.free(owned_dir);

        var self = SpoolQueue{
            .allocator = allocator,
            .spool_dir = owned_dir,
        };

        try self.ensureDir();
        return self;
    }

    pub fn deinit(self: *SpoolQueue) void {
        self.allocator.free(self.spool_dir);
        self.* = undefined;
    }

    pub fn ensureDir(self: *const SpoolQueue) !void {
        const dir_z = try self.allocator.dupeZ(u8, self.spool_dir);
        defer self.allocator.free(dir_z);

        var i: usize = 0;
        while (i < dir_z.len) : (i += 1) {
            if (dir_z[i] == '/' and i > 0) {
                dir_z[i] = 0;
                _ = c.mkdir(dir_z.ptr, 0o755);
                dir_z[i] = '/';
            }
        }
        _ = c.mkdir(dir_z.ptr, 0o755);
    }

    /// Atomically persists a `JobEnvelope` to disk as a `.job` file.
    pub fn push(self: *SpoolQueue, job: JobEnvelope) !void {
        try self.ensureDir();

        const ts: u64 = if (job.timestamp_ns > 0) job.timestamp_ns else @import("envelope.zig").currentTimestampNs();
        // Clean ID for safe filename
        var safe_id_buf: [64]u8 = undefined;
        var safe_len: usize = 0;
        for (job.id) |ch| {
            if (safe_len >= safe_id_buf.len) break;
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                safe_id_buf[safe_len] = ch;
                safe_len += 1;
            }
        }
        const safe_id = if (safe_len > 0) safe_id_buf[0..safe_len] else "job";

        const tmp_name = try std.fmt.allocPrint(self.allocator, "{s}/{d:0>20}_{s}.tmp", .{ self.spool_dir, ts, safe_id });
        defer self.allocator.free(tmp_name);

        const job_name = try std.fmt.allocPrint(self.allocator, "{s}/{d:0>20}_{s}.job", .{ self.spool_dir, ts, safe_id });
        defer self.allocator.free(job_name);

        const json_data = try job.toJson(self.allocator);
        defer self.allocator.free(json_data);

        // 1. Write to temporary file
        const tmp_z = try self.allocator.dupeZ(u8, tmp_name);
        defer self.allocator.free(tmp_z);

        const fp = c.fopen(tmp_z.ptr, "wb") orelse return error.FileCreateFailed;
        var write_ok = true;
        if (json_data.len > 0) {
            const written = c.fwrite(json_data.ptr, 1, json_data.len, fp);
            if (written != json_data.len) write_ok = false;
        }
        _ = c.fclose(fp);

        if (!write_ok) {
            _ = c.unlink(tmp_z.ptr);
            return error.DiskWriteFailed;
        }

        // 2. Atomic rename from .tmp to .job
        const job_z = try self.allocator.dupeZ(u8, job_name);
        defer self.allocator.free(job_z);

        if (c.rename(tmp_z.ptr, job_z.ptr) != 0) {
            _ = c.unlink(tmp_z.ptr);
            return error.FileRenameFailed;
        }
    }

    /// Reads the oldest `.job` file in chronological FIFO order without deleting it.
    pub fn peek(self: *SpoolQueue) !?JobEnvelope {
        const oldest_path = (try self.findOldestJobPath()) orelse return null;
        defer self.allocator.free(oldest_path);

        const content = try self.readFile(oldest_path);
        defer self.allocator.free(content);

        return try JobEnvelope.fromJson(self.allocator, content);
    }

    /// Reads and removes the oldest `.job` file in chronological FIFO order.
    pub fn pop(self: *SpoolQueue) !?JobEnvelope {
        const oldest_path = (try self.findOldestJobPath()) orelse return null;
        defer self.allocator.free(oldest_path);

        const content = try self.readFile(oldest_path);
        defer self.allocator.free(content);

        // Atomically remove from disk once read
        const path_z = try self.allocator.dupeZ(u8, oldest_path);
        defer self.allocator.free(path_z);
        _ = c.unlink(path_z.ptr);

        return try JobEnvelope.fromJson(self.allocator, content);
    }

    /// Returns the number of pending `.job` files currently in the spool directory.
    pub fn count(self: *const SpoolQueue) usize {
        const dir_z = self.allocator.dupeZ(u8, self.spool_dir) catch return 0;
        defer self.allocator.free(dir_z);

        const dir = c.opendir(dir_z.ptr) orelse return 0;
        defer _ = c.closedir(dir);

        var num: usize = 0;
        while (c.readdir(dir)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (std.mem.endsWith(u8, name, ".job")) {
                num += 1;
            }
        }
        return num;
    }

    fn readFile(self: *const SpoolQueue, path: []const u8) ![]u8 {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const fp = c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
        defer _ = c.fclose(fp);

        _ = c.fseek(fp, 0, c.SEEK_END);
        const size_long = c.ftell(fp);
        if (size_long < 0) return error.FileReadFailed;
        const size: usize = @intCast(size_long);
        _ = c.fseek(fp, 0, c.SEEK_SET);

        const buf = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buf);

        if (size > 0) {
            const read_bytes = c.fread(buf.ptr, 1, size, fp);
            if (read_bytes != size) return error.FileReadFailed;
        }
        return buf;
    }

    fn findOldestJobPath(self: *const SpoolQueue) !?[]const u8 {
        const dir_z = try self.allocator.dupeZ(u8, self.spool_dir);
        defer self.allocator.free(dir_z);

        const dir = c.opendir(dir_z.ptr) orelse return null;
        defer _ = c.closedir(dir);

        var oldest_name: ?[]u8 = null;
        defer if (oldest_name) |n| self.allocator.free(n);

        while (c.readdir(dir)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (std.mem.endsWith(u8, name, ".job")) {
                if (oldest_name == null or std.mem.order(u8, name, oldest_name.?).compare(.lt)) {
                    if (oldest_name) |n| self.allocator.free(n);
                    oldest_name = try self.allocator.dupe(u8, name);
                }
            }
        }

        if (oldest_name) |n| {
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.spool_dir, n });
        }
        return null;
    }
};
