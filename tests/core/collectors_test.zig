//! Unit Tests for Flowdata Standalone Collectors Architecture & Spooling (ARCH-019).
//!
//! Verifies:
//! 1. Universal `JobEnvelope` serialization and deserialization (JSON framing, parameters, payload preservation).
//! 2. Persistent `SpoolQueue` store-and-forward disk spooling (chronological FIFO ordering, atomic rename, count).
//! 3. `SpoolForwarder` fallback when Flowdata engine is offline (zero event loss, persistence).

const std = @import("std");
const testing = std.testing;
const collectors = @import("collectors_common");
const JobEnvelope = collectors.JobEnvelope;
const KeyValueParam = collectors.KeyValueParam;
const SpoolQueue = collectors.SpoolQueue;
const SpoolForwarder = collectors.SpoolForwarder;

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("dirent.h");
});

fn cleanDir(allocator: std.mem.Allocator, path: []const u8) void {
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    const dir = c.opendir(path_z.ptr) orelse return;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        var full_buf: [512]u8 = undefined;
        const full = std.fmt.bufPrintZ(&full_buf, "{s}/{s}", .{ path, name }) catch continue;
        _ = c.unlink(full.ptr);
    }
    _ = c.rmdir(path_z.ptr);
}

test "ARCH-019: JobEnvelope JSON serialization and deserialization" {
    const alloc = testing.allocator;

    const params = [_]KeyValueParam{
        .{ .key = "codec", .value = "h264" },
        .{ .key = "fps", .value = "30" },
    };

    const envelope = JobEnvelope{
        .id = "job-42",
        .datasource = "webhook",
        .topic = "video_ingest",
        .timestamp_ns = 1700000000123456789,
        .params = &params,
        .payload_raw = "{\"camera_id\":\"cam-north\",\"status\":\"active\"}",
    };

    // Serialize to JSON
    const json_str = try envelope.toJson(alloc);
    defer alloc.free(json_str);

    try testing.expect(std.mem.indexOf(u8, json_str, "\"id\":\"job-42\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"datasource\":\"webhook\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"topic\":\"video_ingest\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"codec\":\"h264\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"camera_id\":\"cam-north\"") != null);

    // Deserialize back
    var parsed = try JobEnvelope.fromJson(alloc, json_str);
    defer parsed.deinit(alloc);

    try testing.expectEqualStrings("job-42", parsed.id);
    try testing.expectEqualStrings("webhook", parsed.datasource.?);
    try testing.expectEqualStrings("video_ingest", parsed.topic.?);
    try testing.expectEqual(@as(u64, 1700000000123456789), parsed.timestamp_ns);
    try testing.expectEqual(@as(usize, 2), parsed.params.len);
    try testing.expect(parsed.payload_raw != null);
    try testing.expect(std.mem.indexOf(u8, parsed.payload_raw.?, "cam-north") != null);
}

test "ARCH-019: SpoolQueue persists and pops in strict FIFO order" {
    const alloc = testing.allocator;
    const test_spool_dir = "zig-out/test_spool_queue";
    cleanDir(alloc, test_spool_dir);
    defer cleanDir(alloc, test_spool_dir);

    var queue = try SpoolQueue.init(alloc, test_spool_dir);
    defer queue.deinit();

    try testing.expectEqual(@as(usize, 0), queue.count());

    // Push Job 1 (oldest)
    const job1 = JobEnvelope{
        .id = "job-001",
        .datasource = "file_watcher",
        .topic = "logs",
        .timestamp_ns = 1000,
        .payload_raw = "first event",
    };
    try queue.push(job1);

    // Push Job 2 (middle)
    const job2 = JobEnvelope{
        .id = "job-002",
        .datasource = "file_watcher",
        .topic = "logs",
        .timestamp_ns = 2000,
        .payload_raw = "second event",
    };
    try queue.push(job2);

    // Push Job 3 (newest)
    const job3 = JobEnvelope{
        .id = "job-003",
        .datasource = "file_watcher",
        .topic = "logs",
        .timestamp_ns = 3000,
        .payload_raw = "third event",
    };
    try queue.push(job3);

    try testing.expectEqual(@as(usize, 3), queue.count());

    // Peek must return oldest job without removing it
    {
        var peeked = (try queue.peek()).?;
        defer peeked.deinit(alloc);
        try testing.expectEqualStrings("job-001", peeked.id);
        try testing.expectEqual(@as(u64, 1000), peeked.timestamp_ns);
        try testing.expectEqual(@as(usize, 3), queue.count());
    }

    // Pop 1
    {
        var popped1 = (try queue.pop()).?;
        defer popped1.deinit(alloc);
        try testing.expectEqualStrings("job-001", popped1.id);
        try testing.expectEqual(@as(usize, 2), queue.count());
    }

    // Pop 2
    {
        var popped2 = (try queue.pop()).?;
        defer popped2.deinit(alloc);
        try testing.expectEqualStrings("job-002", popped2.id);
        try testing.expectEqual(@as(usize, 1), queue.count());
    }

    // Pop 3
    {
        var popped3 = (try queue.pop()).?;
        defer popped3.deinit(alloc);
        try testing.expectEqualStrings("job-003", popped3.id);
        try testing.expectEqual(@as(usize, 0), queue.count());
    }

    // Queue is now empty
    const empty_peek = try queue.peek();
    try testing.expect(empty_peek == null);
}

test "ARCH-019: SpoolForwarder offline store-and-forward fallback" {
    const alloc = testing.allocator;
    const test_spool_dir = "zig-out/test_spool_forwarder";
    cleanDir(alloc, test_spool_dir);
    defer cleanDir(alloc, test_spool_dir);

    // Target a non-existent port where Flowdata engine is offline
    var forwarder = try SpoolForwarder.init(
        alloc,
        "test-collector",
        "http://127.0.0.1:59999",
        test_spool_dir,
    );
    defer forwarder.deinit();

    try testing.expectEqual(@as(usize, 0), forwarder.spool.count());

    const job = JobEnvelope{
        .id = "offline-job-1",
        .datasource = "webhook",
        .topic = "security_events",
        .timestamp_ns = 5555,
        .payload_raw = "{\"threat_level\":\"high\"}",
    };

    // Dispatching when engine is offline must gracefully spool without crashing or throwing
    const res = try forwarder.send(job);
    try testing.expectEqual(false, res.delivered);
    try testing.expectEqual(true, res.spooled);

    // Spool directory must have recorded the job
    try testing.expectEqual(@as(usize, 1), forwarder.spool.count());

    var spooled_job = (try forwarder.spool.peek()).?;
    defer spooled_job.deinit(alloc);

    try testing.expectEqualStrings("offline-job-1", spooled_job.id);
    try testing.expectEqualStrings("security_events", spooled_job.topic.?);
    try testing.expectEqualStrings("{\"threat_level\":\"high\"}", spooled_job.payload_raw.?);
}

test "ARCH-019: ULID generation and chronological sortability" {
    const Ulid = collectors.Ulid;

    // 1. Generation format check (26 chars, valid Crockford Base32)
    const id1 = Ulid.generate();
    try testing.expectEqual(@as(usize, 26), id1.len);
    for (id1) |ch| {
        try testing.expect(std.mem.indexOfScalar(u8, Ulid.ENCODING, ch) != null);
    }

    // 2. Chronological sortability (k-sortable): earlier timestamp must sort strictly before later timestamp
    const t_earlier: u64 = 1700000000000;
    const t_later: u64 = 1700000001000;
    const id_early = Ulid.generateWithTimestamp(t_earlier);
    const id_late = Ulid.generateWithTimestamp(t_later);

    try testing.expectEqual(std.math.Order.lt, std.mem.order(u8, &id_early, &id_late));

    // 3. Collision resistance: two sequential IDs with same timestamp must differ in randomness
    const id_same_a = Ulid.generateWithTimestamp(t_earlier);
    const id_same_b = Ulid.generateWithTimestamp(t_earlier);
    try testing.expect(!std.mem.eql(u8, &id_same_a, &id_same_b));
}
