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

    // Use a known existing test file in root
    var buf = try ManagedBuffer.initMmap(allocator, "video.mp4");
    defer buf.deinit(allocator);

    try std.testing.expect(buf.size() > 1000);
    try std.testing.expectEqual(BufferKind.mapped_file, buf.kind);

    // Read ftyp box header without loading file into heap RAM
    var header: [8]u8 = undefined;
    try buf.readAt(0, &header);
    try std.testing.expectEqualStrings("ftyp", header[4..8]);

    // Test Copy-on-Write: mutating the buffer promotes it to heap memory
    try buf.writeAt(allocator, 0, "TEST");
    try std.testing.expectEqual(BufferKind.memory, buf.kind);
    try std.testing.expectEqualStrings("TEST", buf.slice()[0..4]);

    // Verify underlying video.mp4 file on disk was NOT mutated
    var fresh_buf = try ManagedBuffer.initMmap(allocator, "video.mp4");
    defer fresh_buf.deinit(allocator);
    var fresh_header: [4]u8 = undefined;
    try fresh_buf.readAt(4, &fresh_header);
    try std.testing.expectEqualStrings("ftyp", &fresh_header);
}

test "ArtifactStore: initFromFile" {
    const allocator = std.testing.allocator;
    var store = try ArtifactStore.initFromFile(allocator, "video.mp4");
    defer store.deinit();

    const root = try store.getBuffer("file");
    try std.testing.expect(root.size() > 0);
    try std.testing.expectEqual(BufferKind.mapped_file, root.kind);
}
