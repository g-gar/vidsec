const std = @import("std");
const mod = @import("vidsec_isobmff");

const c_stdio = @cImport({
    @cInclude("stdio.h");
});

test "FourCC basic operations" {
    const ftyp = mod.FourCC.init("ftyp");
    try std.testing.expect(ftyp.isPrintable());
    try std.testing.expectEqualStrings("ftyp", &ftyp.bytes);

    const ftyp2 = mod.FourCC.fromSlice("ftyp123").?;
    try std.testing.expect(ftyp.equals(ftyp2));

    var buf: [32]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{f}", .{ftyp});
    try std.testing.expectEqualStrings("ftyp", formatted);

    // Non-printable fourcc
    const weird = mod.FourCC{ .bytes = [_]u8{ 0x00, 0x01, 0x02, 0x03 } };
    try std.testing.expect(!weird.isPrintable());
}

test "Parse synthetic valid ISOBMFF stream" {
    const allocator = std.testing.allocator;

    // Construct a minimal valid MP4 container:
    // 1. ftyp box: 24 bytes (size: 24, "ftyp", "isom", minor: 0x00000200, "isom", "mp41")
    // 2. moov container box: 32 bytes (size: 32, "moov", child mvhd: 24 bytes)
    //    child mvhd: 24 bytes (size: 24, "mvhd", version/flags: 0, 12 bytes dummy)
    // 3. mdat box: 16 bytes (size: 16, "mdat", 8 bytes media)
    var stream_buf: [72]u8 = undefined;

    // Box 1: ftyp (24 bytes at offset 0)
    std.mem.writeInt(u32, stream_buf[0..4], 24, .big);
    @memcpy(stream_buf[4..8], "ftyp");
    @memcpy(stream_buf[8..12], "isom");
    std.mem.writeInt(u32, stream_buf[12..16], 0x00000200, .big);
    @memcpy(stream_buf[16..20], "isom");
    @memcpy(stream_buf[20..24], "mp41");

    // Box 2: moov (32 bytes at offset 24..56)
    std.mem.writeInt(u32, stream_buf[24..28], 32, .big);
    @memcpy(stream_buf[28..32], "moov");
    // Child: mvhd (24 bytes at offset 32..56)
    std.mem.writeInt(u32, stream_buf[32..36], 24, .big);
    @memcpy(stream_buf[36..40], "mvhd");
    std.mem.writeInt(u32, stream_buf[40..44], 0, .big); // FullBox version 0, flags 0
    @memcpy(stream_buf[44..56], "123456781234"); // payload

    // Box 3: mdat (16 bytes at offset 56..72)
    std.mem.writeInt(u32, stream_buf[56..60], 16, .big);
    @memcpy(stream_buf[60..64], "mdat");
    @memcpy(stream_buf[64..72], "DEADBEEF");

    const source = mod.ByteSource.fromSlice(stream_buf[0..72]);
    const parser = mod.SafeBoxParser.init(allocator);
    const result = try parser.parse(source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), result.boxes.len);
    try std.testing.expect(result.has_ftyp);
    try std.testing.expect(result.has_moov);
    try std.testing.expectEqual(@as(u32, 1), result.ftyp_count);
    try std.testing.expectEqual(@as(u32, 1), result.moov_count);
    try std.testing.expectEqual(@as(usize, 0), result.issues.len);

    // Verify box roles and hierarchy
    // Box 0: ftyp
    try std.testing.expect(result.boxes[0].header.fourcc.equals(mod.types.BOX_FTYP));
    try std.testing.expectEqual(mod.BoxRole.header, result.boxes[0].role);
    try std.testing.expect(result.boxes[0].parent_id == null);

    // Box 1: moov (container)
    try std.testing.expect(result.boxes[1].header.fourcc.equals(mod.types.BOX_MOOV));
    try std.testing.expectEqual(mod.BoxRole.metadata, result.boxes[1].role);
    try std.testing.expect(result.boxes[1].parent_id == null);
    try std.testing.expectEqual(@as(u32, 1), result.boxes[1].child_count);

    // Box 2: mvhd (child of moov)
    try std.testing.expect(result.boxes[2].header.fourcc.equals(mod.types.BOX_MVHD));
    try std.testing.expectEqual(@as(?u32, 1), result.boxes[2].parent_id);
    try std.testing.expectEqual(@as(u16, 1), result.boxes[2].depth);
    try std.testing.expect(result.boxes[2].is_full_box);

    // Box 3: mdat
    try std.testing.expect(result.boxes[3].header.fourcc.equals(mod.types.BOX_MDAT));
    try std.testing.expectEqual(mod.BoxRole.media_data, result.boxes[3].role);
    try std.testing.expect(result.boxes[3].parent_id == null);
}

test "Detect invalid box size issue" {
    const allocator = std.testing.allocator;

    // Box with size 4 (less than 8 bytes)
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 4, .big);
    @memcpy(buf[4..8], "ftyp");
    @memset(buf[8..16], 0);

    const source = mod.ByteSource.fromSlice(&buf);
    const parser = mod.SafeBoxParser.init(allocator);
    const result = try parser.parse(source);
    defer result.deinit(allocator);

    try std.testing.expect(result.issues.len > 0);
    try std.testing.expectEqual(mod.ParserIssueCode.box_size_invalid, result.issues[0].code);
}

test "Detect box size overflow past EOF" {
    const allocator = std.testing.allocator;

    // File is 20 bytes, but box declares size 100
    var buf: [20]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 100, .big);
    @memcpy(buf[4..8], "ftyp");
    @memset(buf[8..20], 0);

    const source = mod.ByteSource.fromSlice(&buf);
    const parser = mod.SafeBoxParser.init(allocator);
    const result = try parser.parse(source);
    defer result.deinit(allocator);

    var has_overflow = false;
    for (result.issues) |issue| {
        if (issue.code == .box_size_overflow) has_overflow = true;
    }
    try std.testing.expect(has_overflow);
}

test "Detect trailing overlay/slack space" {
    const allocator = std.testing.allocator;

    // Valid ftyp (16 bytes) + moov (16 bytes), but file is 64 bytes (32 bytes trailing)
    var buf: [64]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 16, .big);
    @memcpy(buf[4..8], "ftyp");
    @memset(buf[8..16], 0);

    std.mem.writeInt(u32, buf[16..20], 16, .big);
    @memcpy(buf[20..24], "moov");
    @memset(buf[24..32], 0);

    // Bytes 32..64 are unmapped trailing overlay
    @memset(buf[32..64], 0xAA);

    const source = mod.ByteSource.fromSlice(&buf);
    const parser = mod.SafeBoxParser.init(allocator);
    const result = try parser.parse(source);
    defer result.deinit(allocator);

    var has_trailing = false;
    for (result.issues) |issue| {
        if (issue.code == .orphaned_trailing_data) has_trailing = true;
    }
    try std.testing.expect(has_trailing);
}

test "Parse real MP4 sample file if present" {
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
    const source = mod.ByteSource{
        .ctx = @ptrCast(&ctx),
        .read_at_fn = FileContext.readAt,
        .file_size = file_size,
    };

    const parser = mod.SafeBoxParser.init(allocator);
    const result = try parser.parse(source);
    defer result.deinit(allocator);

    try std.testing.expect(result.boxes.len > 0);
    try std.testing.expect(result.has_ftyp);
    try std.testing.expect(result.has_moov);
    try std.testing.expect(result.boxes.len > 5);
}
