const std = @import("std");
const ir = @import("vidsec_ir");

test "IR: Region Hierarchy and Query Methods" {
    const allocator = std.testing.allocator;

    var container = ir.ContainerIR.init(1000, .isobmff);
    defer container.deinit(allocator);

    // Add root 'ftyp'
    _ = try container.addRegion(allocator, .{
        .id = 1,
        .parent_id = null,
        .tag = [_]u8{ 'f', 't', 'y', 'p' },
        .role = .header,
        .header_offset = 0,
        .payload_offset = 8,
        .size = 24,
    });

    // Add root 'moov'
    _ = try container.addRegion(allocator, .{
        .id = 2,
        .parent_id = null,
        .tag = [_]u8{ 'm', 'o', 'o', 'v' },
        .role = .container,
        .header_offset = 24,
        .payload_offset = 32,
        .size = 300,
    });

    // Add child 'mvhd' inside 'moov' (parent_id = 2)
    _ = try container.addRegion(allocator, .{
        .id = 3,
        .parent_id = 2,
        .tag = [_]u8{ 'm', 'v', 'h', 'd' },
        .role = .metadata,
        .header_offset = 32,
        .payload_offset = 40,
        .size = 108,
    });

    // Add child 'trak' inside 'moov' (parent_id = 2)
    _ = try container.addRegion(allocator, .{
        .id = 4,
        .parent_id = 2,
        .tag = [_]u8{ 't', 'r', 'a', 'k' },
        .role = .container,
        .header_offset = 140,
        .payload_offset = 148,
        .size = 184,
    });

    // 1. Test findRegionById
    const r3 = container.findRegionById(3);
    try std.testing.expect(r3 != null);
    try std.testing.expectEqualStrings("mvhd", r3.?.tagSlice());

    const r99 = container.findRegionById(99);
    try std.testing.expect(r99 == null);

    // 2. Test findFirstByTag
    const moov = container.findFirstByTag([_]u8{ 'm', 'o', 'o', 'v' });
    try std.testing.expect(moov != null);
    try std.testing.expectEqual(@as(u32, 2), moov.?.id);

    // 3. Test getChildren of 'moov' (id = 2)
    const children = try container.getChildren(2, allocator);
    defer allocator.free(children);
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqualStrings("mvhd", children[0].tagSlice());
    try std.testing.expectEqualStrings("trak", children[1].tagSlice());

    // 4. Test removeRegion
    const removed = container.removeRegion(3); // Remove mvhd
    try std.testing.expect(removed);
    try std.testing.expect(container.findRegionById(3) == null);
    try std.testing.expectEqual(@as(usize, 3), container.regions.items.len);
}

test "IR: Geometry and Space Accounting" {
    const allocator = std.testing.allocator;

    // File is 1200 bytes
    var container = ir.ContainerIR.init(1200, .isobmff);
    defer container.deinit(allocator);

    // Root box: header=0, payload=8, size=800 -> payloadSize = 792
    _ = try container.addRegion(allocator, .{
        .id = 1,
        .parent_id = null,
        .tag = [_]u8{ 'm', 'd', 'a', 't' },
        .role = .media_data,
        .header_offset = 0,
        .payload_offset = 8,
        .size = 800,
    });

    // Root box: header=800, payload=808, size=200 -> payloadSize = 192
    _ = try container.addRegion(allocator, .{
        .id = 2,
        .parent_id = null,
        .tag = [_]u8{ 'm', 'o', 'o', 'v' },
        .role = .container,
        .header_offset = 800,
        .payload_offset = 808,
        .size = 200,
    });

    // Highest root end = 1000. File size = 1200. Slack = 200 bytes.
    try std.testing.expectEqual(@as(u64, 1000), container.highestRootEnd());
    try std.testing.expectEqual(@as(u64, 200), container.calculateSlackBytes());

    // Total payload = 792 + 192 = 984 bytes
    try std.testing.expectEqual(@as(u64, 984), container.totalPayloadBytes());
}

test "IR: Media Tracks and Sample Extent Queries" {
    const allocator = std.testing.allocator;

    var container = ir.ContainerIR.init(5000, .isobmff);
    defer container.deinit(allocator);

    // Add audio track (id = 1)
    _ = try container.addTrack(allocator, .{
        .id = 1,
        .kind = .audio,
        .codec_tag = [_]u8{ 'm', 'p', '4', 'a' },
        .timescale = 44100,
        .duration_ticks = 441000, // 10.0 seconds
    });

    // Add video track (id = 2)
    _ = try container.addTrack(allocator, .{
        .id = 2,
        .kind = .video,
        .codec_tag = [_]u8{ 'a', 'v', 'c', '1' },
        .container_width = 1920,
        .container_height = 1080,
        .bitstream_width = 1920,
        .bitstream_height = 1080,
        .timescale = 30000,
        .duration_ticks = 150000, // 5.0 seconds
    });

    // Add samples for audio (track 1)
    _ = try container.addSample(allocator, .{
        .extent_id = 1,
        .track_id = 1,
        .target_offset = 100,
        .byte_size = 500,
    });

    // Add samples for video (track 2)
    _ = try container.addSample(allocator, .{
        .extent_id = 2,
        .track_id = 2,
        .target_offset = 600,
        .byte_size = 2000,
    });
    _ = try container.addSample(allocator, .{
        .extent_id = 3,
        .track_id = 2,
        .target_offset = 2600,
        .byte_size = 1500,
    });

    // 1. Test findPrimaryVideoTrack
    const video_track = container.findPrimaryVideoTrack();
    try std.testing.expect(video_track != null);
    try std.testing.expectEqual(@as(u32, 2), video_track.?.id);
    try std.testing.expectEqual(ir.TrackType.video, video_track.?.kind);

    // 2. Test getTrackDurationSeconds
    const audio_dur = container.getTrackDurationSeconds(1);
    try std.testing.expect(audio_dur != null);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), audio_dur.?, 0.001);

    const video_dur = container.getTrackDurationSeconds(2);
    try std.testing.expect(video_dur != null);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), video_dur.?, 0.001);

    // 3. Test getSamplesForTrack
    const video_samples = try container.getSamplesForTrack(2, allocator);
    defer allocator.free(video_samples);
    try std.testing.expectEqual(@as(usize, 2), video_samples.len);
    try std.testing.expectEqual(@as(u32, 2), video_samples[0].extent_id);
    try std.testing.expectEqual(@as(u32, 3), video_samples[1].extent_id);
}
