const std = @import("std");
const isobmff = @import("vidsec_isobmff");
const mod = @import("vidsec_mp4");

const c_stdio = @cImport({
    @cInclude("stdio.h");
});

test "Mp4Inspector on real video.mp4 sample file" {
    const allocator = std.testing.allocator;
    const path_z = "video.mp4";

    const fp = c_stdio.fopen(path_z, "rb") orelse (c_stdio.fopen("zig-out/out/video.mp4", "rb") orelse return);
    defer _ = c_stdio.fclose(fp);

    if (c_stdio.fseek(fp, 0, c_stdio.SEEK_END) != 0) return;
    const raw_pos = c_stdio.ftell(fp);
    if (raw_pos < 0) return;
    const file_size: u64 = @intCast(raw_pos);

    const FileContext = struct {
        fp: *c_stdio.FILE,

        fn readAt(ctx_ptr: *const anyopaque, buf: []u8, offset: u64) anyerror!usize {
            const self = @as(*const @This(), @ptrCast(@alignCast(ctx_ptr)));
            const off_long: c_long = @intCast(offset);
            if (c_stdio.fseek(self.fp, off_long, c_stdio.SEEK_SET) != 0) return 0;
            return c_stdio.fread(buf.ptr, 1, buf.len, self.fp);
        }
    };

    const ctx = FileContext{ .fp = fp };
    const source = isobmff.ByteSource{
        .ctx = @ptrCast(&ctx),
        .read_at_fn = FileContext.readAt,
        .file_size = file_size,
    };

    // 1. Parse generic ISOBMFF box tree
    const box_parser = isobmff.SafeBoxParser.init(allocator);
    const box_result = try box_parser.parse(source);
    defer box_result.deinit(allocator);

    try std.testing.expect(box_result.boxes.len > 0);

    // 2. Run MP4 specific inspection
    const mp4_inspector = mod.Mp4Inspector.init(allocator);
    const mp4_result = try mp4_inspector.inspect(source, box_result.boxes);
    defer mp4_result.deinit(allocator);

    // Verify ftyp
    try std.testing.expect(mp4_result.ftyp != null);
    const ftyp = mp4_result.ftyp.?;
    try std.testing.expect(ftyp.hasBrand(mod.types.BRAND_ISOM) or ftyp.hasBrand(mod.types.BRAND_MP41) or ftyp.hasBrand(mod.types.BRAND_MP42));

    // Verify tracks
    try std.testing.expect(mp4_result.tracks.len > 0);

    // Find video track
    var has_video = false;
    for (mp4_result.tracks) |tr| {
        if (tr.isVideo()) {
            has_video = true;
            try std.testing.expect(tr.width > 0);
            try std.testing.expect(tr.height > 0);
            try std.testing.expect(tr.sample_count > 0);
            try std.testing.expect(tr.total_sample_bytes > 0);
            if (tr.avcc) |avc| {
                try std.testing.expectEqual(@as(u8, 1), avc.configuration_version);
                try std.testing.expect(avc.sps_count > 0);
                try std.testing.expect(avc.pps_count > 0);
            }
        }
    }
    try std.testing.expect(has_video);
    try std.testing.expect(mp4_result.total_sample_bytes > 0);
}

test "Mp4Inspector detects duplicate track IDs" {
    const allocator = std.testing.allocator;

    // Synthetic box hierarchy:
    // Box 0: ftyp (root, 16 bytes)
    // Box 1: moov (root, container)
    //   Box 2: trak 1 (parent 1, container)
    //     Box 3: tkhd 1 (parent 2, payload with track_id = 1)
    //   Box 4: trak 2 (parent 1, container)
    //     Box 5: tkhd 2 (parent 4, payload with track_id = 1) -> DUPLICATE!
    var stream_buf: [128]u8 = undefined;
    @memset(&stream_buf, 0);

    // Prepare tkhd payload with track_id = 1 (version 0, tid at payloadOffset + 12)
    // Box 3: tkhd 1 at offset 32 (payload offset 40 -> tid at 52)
    std.mem.writeInt(u32, stream_buf[52..56], 1, .big);
    // Box 5: tkhd 2 at offset 64 (payload offset 72 -> tid at 84)
    std.mem.writeInt(u32, stream_buf[84..88], 1, .big);

    const boxes = [_]isobmff.ParsedBox{
        .{
            .id = 0,
            .parent_id = null,
            .depth = 0,
            .header = .{
                .fourcc = isobmff.types.BOX_FTYP,
                .offset = 0,
                .size = 16,
                .header_size = 8,
                .is_extended_size = false,
                .is_eof_size = false,
            },
        },
        .{
            .id = 1,
            .parent_id = null,
            .depth = 0,
            .header = .{
                .fourcc = isobmff.types.BOX_MOOV,
                .offset = 16,
                .size = 112,
                .header_size = 8,
                .is_extended_size = false,
                .is_eof_size = false,
            },
        },
        .{
            .id = 2,
            .parent_id = 1,
            .depth = 1,
            .header = .{
                .fourcc = isobmff.types.BOX_TRAK,
                .offset = 24,
                .size = 40,
                .header_size = 8,
                .is_extended_size = false,
                .is_eof_size = false,
            },
        },
        .{
            .id = 3,
            .parent_id = 2,
            .depth = 2,
            .header = .{
                .fourcc = isobmff.types.BOX_TKHD,
                .offset = 32,
                .size = 32,
                .header_size = 8,
                .is_extended_size = false,
                .is_eof_size = false,
            },
        },
        .{
            .id = 4,
            .parent_id = 1,
            .depth = 1,
            .header = .{
                .fourcc = isobmff.types.BOX_TRAK,
                .offset = 56,
                .size = 40,
                .header_size = 8,
                .is_extended_size = false,
                .is_eof_size = false,
            },
        },
        .{
            .id = 5,
            .parent_id = 4,
            .depth = 2,
            .header = .{
                .fourcc = isobmff.types.BOX_TKHD,
                .offset = 64,
                .size = 32,
                .header_size = 8,
                .is_extended_size = false,
                .is_eof_size = false,
            },
        },
    };

    const source = isobmff.ByteSource.fromSlice(&stream_buf);
    const inspector = mod.Mp4Inspector.init(allocator);
    const result = try inspector.inspect(source, &boxes);
    defer result.deinit(allocator);

    var has_dup = false;
    for (result.issues) |issue| {
        if (issue.code == .track_id_duplicate) has_dup = true;
    }
    try std.testing.expect(has_dup);
}
