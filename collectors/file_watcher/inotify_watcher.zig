const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("collectors_common");
const JobEnvelope = common.JobEnvelope;
const SpoolForwarder = common.SpoolForwarder;

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("sys/inotify.h");
});

/// Foreground Linux inotify directory/file watcher.
/// Emits `JobEnvelope` records on filesystem write/creation events and forwards them with store-and-forward spooling.
pub const InotifyWatcher = struct {
    allocator: Allocator,
    watch_path: []const u8,
    topic: []const u8,
    forwarder: *SpoolForwarder,
    is_running: std.atomic.Value(bool),

    pub fn init(
        allocator: Allocator,
        watch_path: []const u8,
        topic: []const u8,
        forwarder: *SpoolForwarder,
    ) InotifyWatcher {
        return .{
            .allocator = allocator,
            .watch_path = watch_path,
            .topic = topic,
            .forwarder = forwarder,
            .is_running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn stop(self: *InotifyWatcher) void {
        self.is_running.store(false, .release);
    }

    /// Runs the inotify loop in the foreground until interrupted.
    pub fn run(self: *InotifyWatcher) !void {
        const inotify_rc = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
        if (inotify_rc < 0) {
            std.debug.print("[Watcher ERROR] Failed to initialize inotify: code {d}\n", .{inotify_rc});
            return error.InotifyInitFailed;
        }
        const fd: c_int = inotify_rc;
        defer _ = c.close(fd);

        const path_z = try self.allocator.dupeZ(u8, self.watch_path);
        defer self.allocator.free(path_z);

        const mask: u32 = c.IN_CLOSE_WRITE | c.IN_MOVED_TO | c.IN_MODIFY | c.IN_CREATE;
        const watch_rc = c.inotify_add_watch(fd, path_z.ptr, mask);
        if (watch_rc < 0) {
            std.debug.print("[Watcher ERROR] Failed to add inotify watch on '{s}': code {d}\n", .{ self.watch_path, watch_rc });
            return error.InotifyWatchFailed;
        }
        const wd: c_int = watch_rc;
        defer _ = c.inotify_rm_watch(fd, wd);

        std.debug.print("[Watcher] Watching '{s}' (events: CLOSE_WRITE | MOVED_TO | MODIFY | CREATE)\n", .{self.watch_path});

        var poll_fds = [_]c.struct_pollfd{
            .{
                .fd = fd,
                .events = c.POLLIN,
                .revents = 0,
            },
        };

        var event_buf: [8192]u8 align(@alignOf(c.struct_inotify_event)) = undefined;

        while (self.is_running.load(.acquire)) {
            // Periodic flush attempt in case Flowdata reconnected
            _ = self.forwarder.flush() catch {};

            // Poll with 500ms timeout to maintain responsive signal handling and flushing
            const poll_res = c.poll(&poll_fds, 1, 500);
            if (poll_res <= 0) continue;

            if (poll_fds[0].revents & c.POLLIN != 0) {
                const bytes_read = c.read(fd, &event_buf, event_buf.len);
                if (bytes_read <= 0) break;

                var offset: usize = 0;
                const total_bytes: usize = @intCast(bytes_read);
                while (offset + @sizeOf(c.struct_inotify_event) <= total_bytes) {
                    const event_ptr: *const c.struct_inotify_event = @ptrCast(@alignCast(&event_buf[offset]));
                    const name_opt = if (event_ptr.len > 0) std.mem.span(@as([*:0]const u8, @ptrCast(&event_buf[offset + @sizeOf(c.struct_inotify_event)]))) else null;
                    offset += @sizeOf(c.struct_inotify_event) + event_ptr.len;

                    try self.handleEvent(event_ptr.mask, name_opt);
                }
            }
        }

        std.debug.print("[Watcher] Watcher stopped gracefully.\n", .{});
    }

    fn handleEvent(self: *InotifyWatcher, event_mask: u32, event_name: ?[]const u8) !void {
        const ts: u64 = common.currentTimestampNs();
        const name_str = event_name orelse "";

        // Skip hidden temporary files or spool files
        if (std.mem.startsWith(u8, name_str, ".") or std.mem.endsWith(u8, name_str, ".tmp") or std.mem.endsWith(u8, name_str, ".job")) {
            return;
        }

        // Full path of target
        const full_target = if (name_str.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.watch_path, name_str })
        else
            try self.allocator.dupe(u8, self.watch_path);
        defer self.allocator.free(full_target);

        // Read file content if it is a file
        const file_content: ?[]const u8 = self.readFileOrNull(full_target);
        defer if (file_content) |fc| self.allocator.free(fc);

        const ulid_str = common.Ulid.generate();
        const job_id = try std.fmt.allocPrint(self.allocator, "fw_{s}", .{ulid_str});
        defer self.allocator.free(job_id);

        var mask_buf: [32]u8 = undefined;
        const mask_str = try std.fmt.bufPrint(&mask_buf, "0x{x}", .{event_mask});

        const params = [_]common.KeyValueParam{
            .{ .key = "path", .value = full_target },
            .{ .key = "filename", .value = name_str },
            .{ .key = "mask", .value = mask_str },
        };

        const job = JobEnvelope{
            .id = job_id,
            .datasource = "file_watcher",
            .topic = self.topic,
            .timestamp_ns = ts,
            .params = &params,
            .payload_raw = file_content,
        };

        const res = try self.forwarder.send(job);
        if (res.delivered) {
            std.debug.print("[Watcher EVENT] Direct delivered job {s} for '{s}'\n", .{ job_id, full_target });
        } else {
            std.debug.print("[Watcher EVENT] Flowdata offline. Spooled job {s} for '{s}' (spool count: {d})\n", .{
                job_id,
                full_target,
                self.forwarder.spool.count(),
            });
        }
    }

    fn readFileOrNull(self: *InotifyWatcher, path: []const u8) ?[]const u8 {
        const path_z = self.allocator.dupeZ(u8, path) catch return null;
        defer self.allocator.free(path_z);

        const fp = c.fopen(path_z.ptr, "rb") orelse return null;
        defer _ = c.fclose(fp);

        _ = c.fseek(fp, 0, c.SEEK_END);
        const size_long = c.ftell(fp);
        if (size_long <= 0 or size_long > 8 * 1024 * 1024) return null;
        const size: usize = @intCast(size_long);
        _ = c.fseek(fp, 0, c.SEEK_SET);

        const buf = self.allocator.alloc(u8, size) catch return null;
        errdefer self.allocator.free(buf);

        const read_bytes = c.fread(buf.ptr, 1, size, fp);
        if (read_bytes != size) {
            self.allocator.free(buf);
            return null;
        }
        return buf;
    }
};
