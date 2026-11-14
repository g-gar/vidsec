const std = @import("std");
const common = @import("media_ir").common;
const FourCC = @import("fourcc.zig").FourCC;
const BoxHeader = @import("box_header.zig").BoxHeader;
const ByteSource = common.ByteSource;

/// Reads an 8-byte (or 16-byte extended) box header at the given file offset.
pub fn readBoxHeader(source: ByteSource, offset: u64) !?BoxHeader {
    if (offset + 8 > source.file_size) return null;

    var header_buf: [8]u8 = undefined;
    const n = try source.readAt(&header_buf, offset);
    if (n < 8) return null;

    const raw_size = std.mem.readInt(u32, header_buf[0..4], .big);
    const fourcc = FourCC{ .bytes = header_buf[4..8].* };

    if (raw_size == 1) {
        // Extended 64-bit size
        if (offset + 16 > source.file_size) return null;
        var ext_buf: [8]u8 = undefined;
        const ext_n = try source.readAt(&ext_buf, offset + 8);
        if (ext_n < 8) return null;

        const large_size = std.mem.readInt(u64, &ext_buf, .big);
        return BoxHeader{
            .fourcc = fourcc,
            .offset = offset,
            .size = large_size,
            .header_size = 16,
            .is_extended_size = true,
            .is_eof_size = false,
        };
    } else if (raw_size == 0) {
        // Box extends to end of file
        const remaining = source.file_size - offset;
        return BoxHeader{
            .fourcc = fourcc,
            .offset = offset,
            .size = remaining,
            .header_size = 8,
            .is_extended_size = false,
            .is_eof_size = true,
        };
    } else {
        return BoxHeader{
            .fourcc = fourcc,
            .offset = offset,
            .size = @as(u64, raw_size),
            .header_size = 8,
            .is_extended_size = false,
            .is_eof_size = false,
        };
    }
}
