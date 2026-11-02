const std = @import("std");
const types = @import("types.zig");
const MagicInfo = types.MagicInfo;

/// Detects standalone raster image and font formats at offset `0x00`.
/// (Container-based images such as `WebP` inside RIFF or `HEIC`/`AVIF` inside ISOBMFF are classified in `media.zig`).
pub fn detect(buf: []const u8) ?MagicInfo {
    if (buf.len < 2) return null;

    // 1. JPEG XL Naked Codestream (FF 0A)
    if (buf[0] == 0xFF and buf[1] == 0x0A) {
        return .{
            .id = .jxl,
            .category = .image,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "image/jxl",
            .extension = "jxl",
            .description = "JPEG XL Codestream Image",
        };
    }

    // 2. JPEG / JFIF / Exif (FF D8 FF)
    if (buf.len >= 3 and buf[0] == 0xFF and buf[1] == 0xD8 and buf[2] == 0xFF) {
        return .{
            .id = .jpeg,
            .category = .image,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "image/jpeg",
            .extension = "jpg",
            .description = "JPEG Image",
        };
    }

    if (buf.len < 4) return null;

    // 3. PNG Image (89 50 4E 47 0D 0A 1A 0A)
    if (buf.len >= 8 and std.mem.eql(u8, buf[0..8], &.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })) {
        return .{
            .id = .png,
            .category = .image,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "image/png",
            .extension = "png",
            .description = "Portable Network Graphics (PNG)",
        };
    }

    // 4. GIF Image ("GIF87a" or "GIF89a")
    if (buf.len >= 6 and (std.mem.eql(u8, buf[0..6], "GIF87a") or std.mem.eql(u8, buf[0..6], "GIF89a"))) {
        return .{
            .id = .gif,
            .category = .image,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "image/gif",
            .extension = "gif",
            .description = "Graphics Interchange Format (GIF)",
        };
    }

    // 5. TIFF Image (Little-Endian "II*\x00" or Big-Endian "MM\x00*")
    if (std.mem.eql(u8, buf[0..4], "II*\x00")) {
        return .{
            .id = .tiff_le,
            .category = .image,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "image/tiff",
            .extension = "tif",
            .description = "Tagged Image File Format (TIFF Little-Endian)",
        };
    }
    if (std.mem.eql(u8, buf[0..4], "MM\x00*")) {
        return .{
            .id = .tiff_be,
            .category = .image,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "image/tiff",
            .extension = "tif",
            .description = "Tagged Image File Format (TIFF Big-Endian)",
        };
    }

    // 6. Adobe Photoshop PSD ("8BPS\x00\x01")
    if (buf.len >= 6 and std.mem.eql(u8, buf[0..6], "8BPS\x00\x01")) {
        return .{
            .id = .psd,
            .category = .image,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "image/vnd.adobe.photoshop",
            .extension = "psd",
            .description = "Adobe Photoshop Document (PSD)",
        };
    }

    // 7. JPEG XL ISO Container (00 00 00 0C 4A 58 4C 20 0D 0A 87 0A)
    if (buf.len >= 12 and std.mem.eql(u8, buf[0..12], &.{ 0x00, 0x00, 0x00, 0x0C, 'J', 'X', 'L', ' ', 0x0D, 0x0A, 0x87, 0x0A })) {
        return .{
            .id = .jxl,
            .category = .image,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "image/jxl",
            .extension = "jxl",
            .description = "JPEG XL Container Image",
        };
    }

    // 8. QOI ("qoif") & OpenEXR (76 2F 31 01)
    if (std.mem.eql(u8, buf[0..4], "qoif")) {
        return .{
            .id = .qoi,
            .category = .image,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "image/qoi",
            .extension = "qoi",
            .description = "Quite OK Image Format (QOI)",
        };
    }
    if (std.mem.eql(u8, buf[0..4], &.{ 0x76, 0x2F, 0x31, 0x01 })) {
        return .{
            .id = .exr,
            .category = .image,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "image/x-exr",
            .extension = "exr",
            .description = "OpenEXR High Dynamic Range Image",
        };
    }

    // 9. Fonts: OpenType ("OTTO"), WOFF ("wOFF"), WOFF2 ("wOF2"), TrueType (00 01 00 00 00 or "true")
    if (std.mem.eql(u8, buf[0..4], "OTTO")) {
        return .{
            .id = .otf,
            .category = .font,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "font/otf",
            .extension = "otf",
            .description = "OpenType Font (CFF/OTF)",
        };
    }
    if (std.mem.eql(u8, buf[0..4], "wOFF")) {
        return .{
            .id = .woff,
            .category = .font,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "font/woff",
            .extension = "woff",
            .description = "Web Open Font Format 1.0 (WOFF)",
        };
    }
    if (std.mem.eql(u8, buf[0..4], "wOF2")) {
        return .{
            .id = .woff2,
            .category = .font,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "font/woff2",
            .extension = "woff2",
            .description = "Web Open Font Format 2.0 (WOFF2)",
        };
    }
    if ((buf.len >= 5 and std.mem.eql(u8, buf[0..5], &.{ 0x00, 0x01, 0x00, 0x00, 0x00 })) or
        std.mem.eql(u8, buf[0..4], "true"))
    {
        return .{
            .id = .ttf,
            .category = .font,
            .family = .none,
            .threat_class = .benign_asset,
            .mime_type = "font/ttf",
            .extension = "ttf",
            .description = "TrueType Font (TTF)",
        };
    }

    // 10. Windows Bitmap ("BM" + reserved zero bytes at 6..10 + valid DIB header offset at 10..14)
    if (buf.len >= 14 and buf[0] == 'B' and buf[1] == 'M' and
        std.mem.readInt(u32, buf[6..10], .little) == 0)
    {
        const pixel_offset = std.mem.readInt(u32, buf[10..14], .little);
        if (pixel_offset >= 14 and pixel_offset <= 4096) {
            return .{
                .id = .bmp,
                .category = .image,
                .family = .none,
                .threat_class = .benign_asset,
                .mime_type = "image/bmp",
                .extension = "bmp",
                .description = "Windows Bitmap Image (BMP)",
            };
        }
    }

    // 11. Windows Icon (00 00 01 00) & Cursor (00 00 02 00) with non-zero image count at 4..6
    // Checked after TrueType so 00 01 00 00 is never confused.
    if (buf.len >= 6 and buf[0] == 0x00 and buf[1] == 0x00 and buf[3] == 0x00) {
        const count = std.mem.readInt(u16, buf[4..6], .little);
        if (count >= 1 and count <= 64) {
            if (buf[2] == 0x01) {
                return .{
                    .id = .ico,
                    .category = .image,
                    .family = .none,
                    .threat_class = .benign_asset,
                    .mime_type = "image/x-icon",
                    .extension = "ico",
                    .description = "Windows Icon Resource (ICO)",
                };
            }
            if (buf[2] == 0x02) {
                return .{
                    .id = .cur,
                    .category = .image,
                    .family = .none,
                    .threat_class = .benign_asset,
                    .mime_type = "image/x-win-bitmap",
                    .extension = "cur",
                    .description = "Windows Cursor Resource (CUR)",
                };
            }
        }
    }

    return null;
}
