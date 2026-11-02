const std = @import("std");
const vidsec = @import("vidsec");

const ManagedBuffer = vidsec.pipeline.ManagedBuffer;
const BufferKind = vidsec.pipeline.artifact.BufferKind;
const ArtifactStore = vidsec.pipeline.ArtifactStore;

test "ManagedBuffer: memory buffer basic operations" {
    const allocator = std.testing.allocator;
    var buf = try ManagedBuffer.initCopy(allocator, "Hello, VidSec World!");
    defer buf.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 20), buf.size());
    try std.testing.expectEqual(BufferKind.memory, buf.kind);

    var dest: [6]u8 = undefined;
    try buf.readAt(7, &dest);
    try std.testing.expectEqualStrings("VidSec", &dest);

    try buf.readWindowAt(7, 6, 0, &dest);
    try std.testing.expectEqualStrings("VidSec", &dest);

    // Out of bounds window read
    try std.testing.expectError(error.OutOfBounds, buf.readWindowAt(7, 5, 0, &dest));

    // Zero range
    try buf.zeroRange(allocator, 0, 5);
    try std.testing.expectEqualStrings("\x00\x00\x00\x00\x00, VidSec World!", buf.slice());

    // Truncate
    try buf.truncate(allocator, 13);
    try std.testing.expectEqual(@as(u64, 13), buf.size());
}

test "ManagedBuffer: mmap file and Copy-on-Write promotion" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "test_sample.mp4",
        .data = "\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2mp41EXTRA_COW_PAYLOAD_FOR_TESTING_PURPOSES",
    });

    const real_path = try tmp.dir.realPathFileAlloc(std.testing.io, "test_sample.mp4", allocator);
    defer allocator.free(real_path);

    var buf = try ManagedBuffer.initMmap(allocator, real_path);
    defer buf.deinit(allocator);

    try std.testing.expect(buf.size() > 20);
    try std.testing.expectEqual(BufferKind.mapped_file, buf.kind);

    // Read ftyp box header without loading file into heap RAM
    var header: [8]u8 = undefined;
    try buf.readAt(0, &header);
    try std.testing.expectEqualStrings("ftyp", header[4..8]);

    // Test Copy-on-Write: mutating the buffer promotes it to heap memory
    try buf.writeAt(allocator, 0, "TEST");
    try std.testing.expectEqual(BufferKind.memory, buf.kind);
    try std.testing.expectEqualStrings("TEST", buf.slice()[0..4]);

    // Verify underlying file on disk was NOT mutated (Copy-on-Write invariant)
    var fresh_buf = try ManagedBuffer.initMmap(allocator, real_path);
    defer fresh_buf.deinit(allocator);
    var fresh_header: [4]u8 = undefined;
    try fresh_buf.readAt(4, &fresh_header);
    try std.testing.expectEqualStrings("ftyp", &fresh_header);
}

test "ArtifactStore: initFromFile" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "test_store.mp4",
        .data = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41",
    });

    const real_path = try tmp.dir.realPathFileAlloc(std.testing.io, "test_store.mp4", allocator);
    defer allocator.free(real_path);

    var store = try ArtifactStore.initFromFile(allocator, real_path);
    defer store.deinit();

    const root = try store.getBuffer("file");
    try std.testing.expect(root.size() > 0);
    try std.testing.expectEqual(BufferKind.mapped_file, root.kind);
}
