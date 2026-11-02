const std = @import("std");
const ebml = @import("vidsec_ebml");
const mod = @import("vidsec_mkv");

const c_stdio = @cImport({
    @cInclude("stdio.h");
});

test "MkvInspector inspects real Jellyfish_1080_10s_30MB.mkv video track and codec" {
    const path_z = "Jellyfish_1080_10s_30MB.mkv";
    const fp = c_stdio.fopen(path_z, "rb") orelse return;
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
    const source = ebml.types.ByteSource{
        .ctx = &ctx,
        .read_at_fn = FileContext.readAt,
        .file_size = file_size,
    };

    const ebml_parser = ebml.SafeEbmlParser.init(std.testing.allocator, .{
        .recurse_clusters = false,
    });
    const ebml_result = try ebml_parser.parse(source);
    defer ebml_result.deinit(std.testing.allocator);

    const inspector = mod.MkvInspector.init(std.testing.allocator);
    const mkv_result = try inspector.inspect(source, ebml_result.elements);
    defer {
        for (mkv_result.tracks) |t| {
            if (t.codec_id.len > 0) std.testing.allocator.free(t.codec_id);
            if (t.codec_name.len > 0) std.testing.allocator.free(t.codec_name);
        }
        if (mkv_result.info.muxing_app.len > 0) std.testing.allocator.free(mkv_result.info.muxing_app);
        if (mkv_result.info.writing_app.len > 0) std.testing.allocator.free(mkv_result.info.writing_app);
        std.testing.allocator.free(mkv_result.tracks);
        std.testing.allocator.free(mkv_result.issues);
    }

    try std.testing.expectEqual(@as(usize, 1), mkv_result.tracks.len);
    const track0 = mkv_result.tracks[0];
    try std.testing.expect(track0.isVideo());
    try std.testing.expectEqualStrings("V_MPEG4/ISO/AVC", track0.codec_id);
    try std.testing.expect(track0.video != null);
    try std.testing.expectEqual(@as(u32, 1920), track0.video.?.pixel_width);
    try std.testing.expectEqual(@as(u32, 1080), track0.video.?.pixel_height);
    try std.testing.expect(mkv_result.cluster_count > 0);
    try std.testing.expect(mkv_result.total_cluster_bytes > 0);
    try std.testing.expectEqual(@as(usize, 0), mkv_result.issues.len);
}
