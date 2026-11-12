const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("time.h");
});

/// Gets the current monotonic/realtime timestamp in nanoseconds using POSIX clock_gettime.
pub fn currentTimestampNs() u64 {
    var ts_spec: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts_spec);
    const sec: i64 = @intCast(ts_spec.tv_sec);
    const nsec: i64 = @intCast(ts_spec.tv_nsec);
    const total = sec * 1_000_000_000 + nsec;
    return if (total > 0) @intCast(total) else 0;
}

/// Represents a key-value parameter passed to an inbound job.
pub const KeyValueParam = struct {
    key: []const u8,
    value: []const u8,
};

/// Universal Inbound Job Envelope (ARCH-019).
/// Format accepted by Flowdata HTTP/RPC API (`POST /v1/jobs`) and emitted by all standalone collectors.
pub const JobEnvelope = struct {
    id: []const u8,
    datasource: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    timestamp_ns: u64 = 0,
    params: []const KeyValueParam = &.{},
    payload_raw: ?[]const u8 = null,

    /// Serializes this envelope to a compact JSON string.
    pub fn toJson(self: JobEnvelope, alloc: Allocator) ![]u8 {
        var params_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer params_buf.deinit(alloc);

        for (self.params, 0..) |p, i| {
            if (i > 0) try params_buf.append(alloc, ',');
            const item = try std.fmt.allocPrint(alloc, "\"{s}\":\"{s}\"", .{ p.key, p.value });
            defer alloc.free(item);
            try params_buf.appendSlice(alloc, item);
        }

        const ds_part = if (self.datasource) |ds| try std.fmt.allocPrint(alloc, ",\"datasource\":\"{s}\"", .{ds}) else try alloc.dupe(u8, "");
        defer alloc.free(ds_part);

        const topic_part = if (self.topic) |t| try std.fmt.allocPrint(alloc, ",\"topic\":\"{s}\"", .{t}) else try alloc.dupe(u8, "");
        defer alloc.free(topic_part);

        const params_part = if (params_buf.items.len > 0) try std.fmt.allocPrint(alloc, ",\"params\":{{{s}}}", .{params_buf.items}) else try alloc.dupe(u8, "");
        defer alloc.free(params_part);

        const payload_part = if (self.payload_raw) |pl| blk: {
            const trimmed = std.mem.trim(u8, pl, " \t\r\n");
            if (trimmed.len > 0 and ((trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') or (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']'))) {
                break :blk try std.fmt.allocPrint(alloc, ",\"payload_raw\":{s}", .{trimmed});
            } else {
                break :blk try std.fmt.allocPrint(alloc, ",\"payload_raw\":\"{s}\"", .{pl});
            }
        } else try alloc.dupe(u8, "");
        defer alloc.free(payload_part);

        return std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\"{s}{s},\"timestamp_ns\":{d}{s}{s}}}", .{
            self.id,
            ds_part,
            topic_part,
            self.timestamp_ns,
            params_part,
            payload_part,
        });
    }

    /// Deserializes a `JobEnvelope` from a JSON slice.
    pub fn fromJson(alloc: Allocator, json_bytes: []const u8) !JobEnvelope {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidJsonEnvelope;

        const id_val = root.object.get("id") orelse return error.MissingEnvelopeId;
        if (id_val != .string) return error.InvalidEnvelopeId;
        const id_str = try alloc.dupe(u8, id_val.string);
        errdefer alloc.free(id_str);

        var datasource_str: ?[]const u8 = null;
        if (root.object.get("datasource")) |ds_val| {
            if (ds_val == .string) {
                datasource_str = try alloc.dupe(u8, ds_val.string);
            }
        }
        errdefer if (datasource_str) |ds| alloc.free(ds);

        var topic_str: ?[]const u8 = null;
        if (root.object.get("topic")) |t_val| {
            if (t_val == .string) {
                topic_str = try alloc.dupe(u8, t_val.string);
            }
        }
        errdefer if (topic_str) |t| alloc.free(t);

        var ts: u64 = 0;
        if (root.object.get("timestamp_ns")) |ts_val| {
            switch (ts_val) {
                .integer => |i| ts = if (i >= 0) @intCast(i) else 0,
                else => {},
            }
        }

        var params_list: std.ArrayListUnmanaged(KeyValueParam) = .empty;
        errdefer {
            for (params_list.items) |p| {
                alloc.free(p.key);
                alloc.free(p.value);
            }
            params_list.deinit(alloc);
        }

        if (root.object.get("params")) |params_val| {
            if (params_val == .object) {
                var it = params_val.object.iterator();
                while (it.next()) |entry| {
                    const k = try alloc.dupe(u8, entry.key_ptr.*);
                    errdefer alloc.free(k);

                    var v: []u8 = undefined;
                    switch (entry.value_ptr.*) {
                        .string => |sv| v = try alloc.dupe(u8, sv),
                        .integer => |iv| v = try std.fmt.allocPrint(alloc, "{d}", .{iv}),
                        .float => |fv| v = try std.fmt.allocPrint(alloc, "{d}", .{fv}),
                        .bool => |bv| v = try alloc.dupe(u8, if (bv) "true" else "false"),
                        else => v = try alloc.dupe(u8, ""),
                    }
                    try params_list.append(alloc, .{ .key = k, .value = v });
                }
            }
        }

        var payload_raw: ?[]const u8 = null;
        if (root.object.get("payload_raw")) |pl_val| {
            switch (pl_val) {
                .string => |s| payload_raw = try alloc.dupe(u8, s),
                .object, .array => {
                    payload_raw = try std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(pl_val, .{})});
                },
                else => {},
            }
        }
        errdefer if (payload_raw) |pl| alloc.free(pl);

        return JobEnvelope{
            .id = id_str,
            .datasource = datasource_str,
            .topic = topic_str,
            .timestamp_ns = ts,
            .params = try params_list.toOwnedSlice(alloc),
            .payload_raw = payload_raw,
        };
    }

    /// Frees memory allocated by `fromJson` or dynamic clones.
    pub fn deinit(self: *JobEnvelope, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.datasource) |ds| alloc.free(ds);
        if (self.topic) |t| alloc.free(t);
        for (self.params) |p| {
            alloc.free(p.key);
            alloc.free(p.value);
        }
        if (self.params.len > 0) alloc.free(self.params);
        if (self.payload_raw) |pl| alloc.free(pl);
        self.* = undefined;
    }
};
