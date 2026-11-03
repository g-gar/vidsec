const std = @import("std");
const ir = @import("vidsec_ir");
const forensics = @import("vidsec_forensics");

test "Forensics: Single-Responsibility Underflow and Overflow Checkers" {
    const allocator = std.testing.allocator;

    var container = ir.ContainerIR.init(1000, .isobmff);
    defer container.deinit(allocator);

    // 1. Normal box
    _ = try container.addRegion(allocator, .{
        .id = 1,
        .tag = [_]u8{ 'f', 't', 'y', 'p' },
        .role = .header,
        .header_offset = 0,
        .payload_offset = 8,
        .size = 24,
    });

    // 2. Underflow box (< 8 bytes)
    _ = try container.addRegion(allocator, .{
        .id = 2,
        .tag = [_]u8{ 'b', 'a', 'd', '1' },
        .role = .metadata,
        .header_offset = 24,
        .payload_offset = 28,
        .size = 4,
    });

    // 3. Overflow box (extends past 1000 to 1200)
    _ = try container.addRegion(allocator, .{
        .id = 3,
        .tag = [_]u8{ 'm', 'd', 'a', 't' },
        .role = .media_data,
        .header_offset = 500,
        .payload_offset = 508,
        .size = 700,
    });

    // Test checkHeaderUnderflow in isolation
    {
        var underflow_findings = forensics.FindingList.init();
        defer {
            for (underflow_findings.items.items) |f| allocator.free(f.message);
            underflow_findings.deinit(allocator);
        }
        try forensics.checkHeaderUnderflow(allocator, &container, &underflow_findings);
        try std.testing.expectEqual(@as(usize, 1), underflow_findings.items.items.len);
        try std.testing.expect(underflow_findings.hasVulnerability(.header_underflow));
    }

    // Test checkRegionOverflow in isolation
    {
        var overflow_findings = forensics.FindingList.init();
        defer {
            for (overflow_findings.items.items) |f| allocator.free(f.message);
            overflow_findings.deinit(allocator);
        }
        try forensics.checkRegionOverflow(allocator, &container, &overflow_findings);
        try std.testing.expectEqual(@as(usize, 1), overflow_findings.items.items.len);
        try std.testing.expect(overflow_findings.hasVulnerability(.region_overflow));
    }
}

test "Forensics: Single-Responsibility Topology Checkers" {
    const allocator = std.testing.allocator;

    // File is 1500 bytes, but highest root box ends at 1000 -> 500 bytes trailing overlay
    var container = ir.ContainerIR.init(1500, .isobmff);
    defer container.deinit(allocator);

    // Box 1: [10..100] -> Leading gap of 10 bytes
    _ = try container.addRegion(allocator, .{
        .id = 1,
        .parent_id = null,
        .tag = [_]u8{ 'f', 't', 'y', 'p' },
        .role = .header,
        .header_offset = 10,
        .payload_offset = 18,
        .size = 90,
    });

    // Box 2: [150..500] -> Gap of 50 bytes between Box 1 and Box 2
    _ = try container.addRegion(allocator, .{
        .id = 2,
        .parent_id = null,
        .tag = [_]u8{ 'm', 'o', 'o', 'v' },
        .role = .container,
        .header_offset = 150,
        .payload_offset = 158,
        .size = 350,
    });

    // Box 3: [450..1000] -> Overlaps with Box 2 by 50 bytes [450..500]
    _ = try container.addRegion(allocator, .{
        .id = 3,
        .parent_id = null,
        .tag = [_]u8{ 'm', 'd', 'a', 't' },
        .role = .media_data,
        .header_offset = 450,
        .payload_offset = 458,
        .size = 550,
    });

    // 1. Test checkTrailingOverlay alone
    {
        var findings = forensics.FindingList.init();
        defer {
            for (findings.items.items) |f| allocator.free(f.message);
            findings.deinit(allocator);
        }
        try forensics.checkTrailingOverlay(allocator, &container, &findings);
        try std.testing.expectEqual(@as(usize, 1), findings.items.items.len);
        try std.testing.expect(findings.hasVulnerability(.trailing_overlay));
    }

    // 2. Test checkLeadingGap alone
    {
        var findings = forensics.FindingList.init();
        defer {
            for (findings.items.items) |f| allocator.free(f.message);
            findings.deinit(allocator);
        }
        try forensics.checkLeadingGap(allocator, &container, &findings);
        try std.testing.expectEqual(@as(usize, 1), findings.items.items.len);
        try std.testing.expect(findings.hasVulnerability(.leading_gap));
    }

    // 3. Test checkUnreferencedGaps alone
    {
        var findings = forensics.FindingList.init();
        defer {
            for (findings.items.items) |f| allocator.free(f.message);
            findings.deinit(allocator);
        }
        try forensics.checkUnreferencedGaps(allocator, &container, &findings);
        try std.testing.expectEqual(@as(usize, 1), findings.items.items.len);
        try std.testing.expect(findings.hasVulnerability(.unreferenced_gap));
    }

    // 4. Test checkRegionOverlaps alone
    {
        var findings = forensics.FindingList.init();
        defer {
            for (findings.items.items) |f| allocator.free(f.message);
            findings.deinit(allocator);
        }
        try forensics.checkRegionOverlaps(allocator, &container, &findings);
        try std.testing.expectEqual(@as(usize, 1), findings.items.items.len);
        try std.testing.expect(findings.hasVulnerability(.region_overlap));
    }
}

test "Forensics: Single-Responsibility Sample and Codec Checkers" {
    const allocator = std.testing.allocator;

    var container = ir.ContainerIR.init(2000, .isobmff);
    defer container.deinit(allocator);

    _ = try container.addTrack(allocator, .{
        .id = 1,
        .kind = .video,
        .codec_tag = [_]u8{ 'a', 'v', 'c', '1' },
        .container_width = 1920,
        .container_height = 1080,
        .bitstream_width = 3840,
        .bitstream_height = 2160,
    });

    _ = try container.addSample(allocator, .{
        .extent_id = 1,
        .track_id = 1,
        .target_offset = 1800,
        .byte_size = 500, // end = 2300 > 2000
    });

    // Test checkCodecMismatches
    {
        var findings = forensics.FindingList.init();
        defer {
            for (findings.items.items) |f| allocator.free(f.message);
            findings.deinit(allocator);
        }
        try forensics.checkCodecMismatches(allocator, &container, &findings);
        try std.testing.expect(findings.hasVulnerability(.dimension_mismatch));
    }

    // Test checkSampleOverflows
    {
        var findings = forensics.FindingList.init();
        defer {
            for (findings.items.items) |f| allocator.free(f.message);
            findings.deinit(allocator);
        }
        try forensics.checkSampleOverflows(allocator, &container, &findings);
        try std.testing.expect(findings.hasVulnerability(.sample_overflow));
    }
}

test "Forensics: Single-Responsibility Entropy Checker over ByteStream" {
    const allocator = std.testing.allocator;

    var buffer: [2048]u8 = [_]u8{0} ** 2048;
    var prng = std.Random.DefaultPrng.init(0x12345678);
    prng.fill(buffer[1024..2048]);

    const slice_stream = ir.SliceStream.init(&buffer);
    const stream = slice_stream.byteStream();

    var container = ir.ContainerIR.init(2048, .isobmff);
    defer container.deinit(allocator);

    _ = try container.addRegion(allocator, .{
        .id = 1,
        .parent_id = null,
        .tag = [_]u8{ 'm', 'd', 'a', 't' },
        .role = .media_data,
        .header_offset = 0,
        .payload_offset = 8,
        .size = 1024,
    });

    var findings = forensics.FindingList.init();
    defer {
        for (findings.items.items) |f| allocator.free(f.message);
        findings.deinit(allocator);
    }

    try forensics.checkEntropyPayloads(allocator, &container, stream, .{}, &findings);
    try std.testing.expect(findings.hasVulnerability(.high_entropy_payload));
}

test "Forensics: Full runAllForensics Composite Suite" {
    const allocator = std.testing.allocator;

    var container = ir.ContainerIR.init(100, .isobmff);
    defer container.deinit(allocator);

    _ = try container.addRegion(allocator, .{
        .id = 1,
        .parent_id = null,
        .tag = [_]u8{ 'f', 't', 'y', 'p' },
        .role = .header,
        .header_offset = 0,
        .payload_offset = 8,
        .size = 100,
    });

    var findings = forensics.FindingList.init();
    defer {
        for (findings.items.items) |f| allocator.free(f.message);
        findings.deinit(allocator);
    }

    try forensics.runAllForensics(allocator, &container, null, .{}, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.items.len);
}
