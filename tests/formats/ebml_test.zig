const std = @import("std");
const ebml = @import("vidsec_ebml");

const types = ebml.types;
const vint = ebml.vint;
const reader = ebml.reader;

const c_stdio = @cImport({
    @cInclude("stdio.h");
});

test "VINT slice decoding handles 1, 2, 3, 4 octet widths and unknown size markers" {
    // 1-octet: 0x85 -> length 1, data 5
    const v1 = vint.readVintSlice("\x85").?;
    try std.testing.expectEqual(@as(u8, 1), v1.length);
    try std.testing.expectEqual(@as(u64, 5), v1.data_value);
    try std.testing.expect(!v1.is_all_ones);

    // 1-octet all ones: 0xFF -> length 1, data 0x7F, is_all_ones true
    const v1_ones = vint.readVintSlice("\xFF").?;
    try std.testing.expectEqual(@as(u8, 1), v1_ones.length);
    try std.testing.expect(v1_ones.is_all_ones);

    // 2-octet: 0x40 0x05 -> length 2, data 5
    const v2 = vint.readVintSlice("\x40\x05").?;
    try std.testing.expectEqual(@as(u8, 2), v2.length);
    try std.testing.expectEqual(@as(u64, 5), v2.data_value);
    try std.testing.expect(!v2.is_all_ones);

    // 4-octet Element ID: EBML Header (0x1A 0x45 0xDF 0xA3)
    const v4 = vint.readVintSlice("\x1A\x45\xDF\xA3").?;
    try std.testing.expectEqual(@as(u8, 4), v4.length);
    try std.testing.expectEqual(@as(u64, 0x1A45DFA3), v4.raw_value);

    // Invalid: leading byte 0x00
    try std.testing.expect(vint.readVintSlice("\x00\x01") == null);
}

test "SafeEbmlParser parses synthetic EBML Header and reports doctype" {
    // Synthetic minimal EBML header:
    // [0x1A, 0x45, 0xDF, 0xA3] (EBML, 4 bytes)
    // [0x94] (size 20)
    //   [0x42, 0x86] (EBMLVersion, 2 bytes) [0x81, 0x01] (val 1)
    //   [0x42, 0xF7] (EBMLReadVersion, 2 bytes) [0x81, 0x01] (val 1)
    //   [0x42, 0x82] (DocType, 2 bytes) [0x88] (size 8) "matroska"
    //   [0x42, 0x87] (DocTypeVersion, 2 bytes) [0x81, 0x04] (val 4)
    const synthetic_ebml = "\x1A\x45\xDF\xA3\x94\x42\x86\x81\x01\x42\xF7\x81\x01\x42\x82\x88matroska\x42\x87\x81\x04";

    const source = types.ByteSource.fromSlice(synthetic_ebml);
    const parser = reader.SafeEbmlParser.init(std.testing.allocator, .{});
    const result = try parser.parse(source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_ebml_header);
    try std.testing.expectEqualStrings("matroska", result.doc_type);
    try std.testing.expectEqual(@as(u32, 4), result.doc_type_version);
    try std.testing.expect(result.elements.len >= 5);
    try std.testing.expectEqual(types.ID_EBML_HEADER, result.elements[0].id);
    try std.testing.expectEqual(@as(u16, 0), result.elements[0].depth);
}

test "SafeEbmlParser parses real Jellyfish_1080_10s_30MB.mkv cleanly" {
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
    const source = types.ByteSource{
        .ctx = &ctx,
        .read_at_fn = FileContext.readAt,
        .file_size = file_size,
    };

    const parser = reader.SafeEbmlParser.init(std.testing.allocator, .{
        .recurse_clusters = false,
    });
    const result = try parser.parse(source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_ebml_header);
    try std.testing.expect(result.has_segment);
    try std.testing.expectEqualStrings("matroska", result.doc_type);
    try std.testing.expect(result.cluster_count > 0);
    try std.testing.expect(result.total_cluster_bytes > 0);
    try std.testing.expect(result.elements.len > 10);
    try std.testing.expectEqual(@as(u64, 0), result.trailing_slack_bytes);
}
