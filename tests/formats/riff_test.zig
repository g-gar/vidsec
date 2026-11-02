const std = @import("std");
const riff_mod = @import("vidsec_riff");

const types = riff_mod.types;
const reader = riff_mod.reader;

const c_stdio = @cImport({
    @cInclude("stdio.h");
});

test "FourCC helpers for RIFF" {
    const riff = types.FourCC.init("RIFF");
    try std.testing.expect(riff.isPrintable());
    try std.testing.expectEqualStrings("RIFF", &riff.bytes);
    try std.testing.expect(riff.equals(types.FOURCC_RIFF));
}

test "SafeRiffParser parses synthetic RIFF/AVI container" {
    // Construct a minimal valid RIFF AVI (48 bytes total):
    // 0..4: 'RIFF'
    // 4..8: size (40 = 4 + 24 + 12)
    // 8..12: 'AVI '
    // 12..36: 'LIST' chunk (size: 16 = 4 'hdrl' + 12 'avih')
    //   20..24: 'hdrl'
    //   24..36: 'avih' chunk (size: 4, dummy)
    // 36..48: 'LIST' chunk (size: 4 = 4 'movi')
    //   44..48: 'movi'
    var buf: [48]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 40, .little);
    @memcpy(buf[8..12], "AVI ");

    // LIST hdrl (size 16)
    @memcpy(buf[12..16], "LIST");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    @memcpy(buf[20..24], "hdrl");

    // child avih inside hdrl (size 4)
    @memcpy(buf[24..28], "avih");
    std.mem.writeInt(u32, buf[28..32], 4, .little);
    @memset(buf[32..36], 0);

    // LIST movi (size 4)
    @memcpy(buf[36..40], "LIST");
    std.mem.writeInt(u32, buf[40..44], 4, .little);
    @memcpy(buf[44..48], "movi");

    const source = types.ByteSource.fromSlice(&buf);
    const parser = reader.SafeRiffParser.init(std.testing.allocator, .{});
    const result = try parser.parse(source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("AVI ", &result.form_type.bytes);
    try std.testing.expect(result.chunks.len >= 3);
    try std.testing.expectEqual(@as(usize, 0), result.issues.len);
}

test "SafeRiffParser parses real bird.avi" {
    const path_z = "bird.avi";
    const fp = c_stdio.fopen(path_z, "rb") orelse (c_stdio.fopen("zig-out/out/bird.avi", "rb") orelse return);
    defer _ = c_stdio.fclose(fp);

    if (c_stdio.fseek(fp, 0, c_stdio.SEEK_END) != 0) return;
    const raw_pos = c_stdio.ftell(fp);
    if (raw_pos < 0) return;
    const file_size: u64 = @intCast(raw_pos);

    const FileContext = struct {
        file: *c_stdio.FILE,
        fn readAt(ctx_ptr: *const anyopaque, buf: []u8, offset: u64) anyerror!usize {
            const self = @as(*const @This(), @ptrCast(@alignCast(ctx_ptr)));
            const pos: c_long = @intCast(offset);
            if (c_stdio.fseek(self.file, pos, c_stdio.SEEK_SET) != 0) return 0;
            return c_stdio.fread(buf.ptr, 1, buf.len, self.file);
        }
    };

    const ctx = FileContext{ .file = fp };
    const source = types.ByteSource{
        .ctx = &ctx,
        .read_at_fn = FileContext.readAt,
        .file_size = file_size,
    };

    const parser = reader.SafeRiffParser.init(std.testing.allocator, .{
        .recurse_movi = false,
    });
    const result = try parser.parse(source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("AVI ", &result.form_type.bytes);
    try std.testing.expect(result.chunks.len >= 5);
    try std.testing.expect(result.movi_bytes > 0);
    // 22 bytes of standard trailing pad/slack
    try std.testing.expectEqual(@as(u64, 22), result.trailing_slack_bytes);
}
