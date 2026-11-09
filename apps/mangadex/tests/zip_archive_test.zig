const std = @import("std");
const zip_archive = @import("zip_archive");
const ZipArchiveWriter = zip_archive.ZipArchiveWriter;
const ZipArchiveReader = zip_archive.ZipArchiveReader;

test "Archive Integrity: create, add entries with mixed compression, finalize and read back" {
    const allocator = std.testing.allocator;
    const zip_path = "/tmp/test_archive_integrity_main.zip";
    _ = std.c.unlink(zip_path);
    defer _ = std.c.unlink(zip_path);

    // 1. Create and populate zip archive
    {
        var writer = try ZipArchiveWriter.create(allocator, zip_path);
        defer writer.deinit();

        // Entry 1: Deflated text
        const text_content = "This is a text metadata or readme file that deflates nicely. " ** 10;
        try writer.addFileFromMemory("metadata.txt", text_content, .default);

        // Entry 2: Binary block (store mode)
        const bin_1 = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46 };
        try writer.addFileFromMemory("001.jpg", &bin_1, .store);

        // Entry 3: Second binary block (store mode)
        const bin_2 = [_]u8{ 0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50 };
        try writer.addFileFromMemory("002.webp", &bin_2, .store);

        try writer.finish();
    }

    // 2. Read back and verify with ZipArchiveReader
    {
        var reader = try ZipArchiveReader.openFile(allocator, zip_path);
        defer reader.deinit();

        try std.testing.expectEqual(@as(usize, 3), reader.getNumFiles());

        var name_buf: [256]u8 = undefined;

        // Check entry 0
        const name0 = (try reader.getFileName(0, &name_buf)).?;
        try std.testing.expectEqualStrings("metadata.txt", name0);
        const data0 = try reader.readFileToMemory(allocator, 0);
        defer allocator.free(data0);
        const expected_text = "This is a text metadata or readme file that deflates nicely. " ** 10;
        try std.testing.expectEqualStrings(expected_text, data0);

        // Check entry 1
        const name1 = (try reader.getFileName(1, &name_buf)).?;
        try std.testing.expectEqualStrings("001.jpg", name1);
        const data1 = try reader.readFileByNameToMemory(allocator, "001.jpg");
        defer allocator.free(data1);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46 }, data1);

        // Check entry 2
        const name2 = (try reader.getFileName(2, &name_buf)).?;
        try std.testing.expectEqualStrings("002.webp", name2);
        const data2 = try reader.readFileByNameToMemory(allocator, "002.webp");
        defer allocator.free(data2);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50 }, data2);

        // Non-existent file
        try std.testing.expectError(error.FileNotFound, reader.readFileByNameToMemory(allocator, "does_not_exist.png"));
    }
}

test "Store Mode Performance: 50 pre-compressed image buffers" {
    const allocator = std.testing.allocator;
    const zip_path = "/tmp/test_perf_main.cbz";
    _ = std.c.unlink(zip_path);
    defer _ = std.c.unlink(zip_path);

    // 50 pages of 16KB each
    const dummy_page = [_]u8{0xAA} ** (16 * 1024);

    var ts_start: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_start);

    {
        var writer = try ZipArchiveWriter.create(allocator, zip_path);
        defer writer.deinit();

        var i: usize = 0;
        while (i < 50) : (i += 1) {
            var filename_buf: [32]u8 = undefined;
            const filename = try std.fmt.bufPrint(&filename_buf, "page_{d:0>3}.jpg", .{i + 1});
            try writer.addFileFromMemory(filename, &dummy_page, .store);
        }

        try writer.finish();
    }

    var ts_end: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_end);
    const elapsed_ms = (ts_end.sec - ts_start.sec) * 1000 + @divTrunc(ts_end.nsec - ts_start.nsec, 1_000_000);

    // Verify performance: writing 50 pre-compressed pages in store mode should be well under 100ms
    try std.testing.expect(elapsed_ms < 100);

    // Verify resulting archive has exactly 50 files
    var reader = try ZipArchiveReader.openFile(allocator, zip_path);
    defer reader.deinit();
    try std.testing.expectEqual(@as(usize, 50), reader.getNumFiles());
}
