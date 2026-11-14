const std = @import("std");
const types = @import("types.zig");
const MagicInfo = types.MagicInfo;

/// Detects archive, package, and compressed stream signatures at offset `0x00` (and TAR `ustar` at `257`).
/// Evaluated BEFORE multimedia headers so polyglot archives (`ZIP`/`JAR`/`RAR`) are flagged immediately.
pub fn detect(buf: []const u8) ?MagicInfo {
    if (buf.len < 3) return null;

    // 1. GZIP (1F 8B 08)
    if (buf[0] == 0x1F and buf[1] == 0x8B and buf[2] == 0x08) {
        return .{
            .id = .gzip,
            .category = .archive,
            .family = .none,
            .mime_type = "application/gzip",
            .extension = "gz",
            .description = "GZIP Compressed Archive",
        };
    }

    // 2. BZIP2 ("BZh" + block size '1'..'9')
    if (buf.len >= 4 and std.mem.eql(u8, buf[0..3], "BZh") and (buf[3] >= '1' and buf[3] <= '9')) {
        return .{
            .id = .bzip2,
            .category = .archive,
            .family = .none,
            .mime_type = "application/x-bzip2",
            .extension = "bz2",
            .description = "BZIP2 Compressed Data",
        };
    }

    if (buf.len < 4) return null;

    // 3. ZIP / JAR / APK / EPUB / OOXML / ODF ("PK\x03\x04", "PK\x05\x06" empty, "PK\x07\x08" spanned)
    if (std.mem.eql(u8, buf[0..4], "PK\x03\x04") or
        std.mem.eql(u8, buf[0..4], "PK\x05\x06") or
        std.mem.eql(u8, buf[0..4], "PK\x07\x08"))
    {
        return classifyZipContainer(buf);
    }

    // 4. RAR Archive (v5: 52 61 72 21 1A 07 01 00, v4: 52 61 72 21 1A 07 00)
    if (buf.len >= 7 and std.mem.eql(u8, buf[0..6], "Rar!\x1A\x07")) {
        if (buf.len >= 8 and buf[6] == 0x01 and buf[7] == 0x00) {
            return .{
                .id = .rar_v5,
                .category = .archive,
                .family = .none,
                .mime_type = "application/vnd.rar",
                .extension = "rar",
                .description = "RAR Archive v5",
            };
        }
        if (buf[6] == 0x00) {
            return .{
                .id = .rar_v4,
                .category = .archive,
                .family = .none,
                .mime_type = "application/vnd.rar",
                .extension = "rar",
                .description = "RAR Archive v4",
            };
        }
    }

    // 5. 7-Zip Archive (37 7A BC AF 27 1C)
    if (buf.len >= 6 and std.mem.eql(u8, buf[0..6], &.{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C })) {
        return .{
            .id = .seven_z,
            .category = .archive,
            .family = .none,
            .mime_type = "application/x-7z-compressed",
            .extension = "7z",
            .description = "7-Zip Archive",
        };
    }

    // 6. XZ Compressed Stream (FD 37 7A 58 5A 00)
    if (buf.len >= 6 and std.mem.eql(u8, buf[0..6], &.{ 0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00 })) {
        return .{
            .id = .xz,
            .category = .archive,
            .family = .none,
            .mime_type = "application/x-xz",
            .extension = "xz",
            .description = "XZ Compressed Data",
        };
    }

    // 7. Zstandard (28 B5 2F FD)
    if (std.mem.eql(u8, buf[0..4], &.{ 0x28, 0xB5, 0x2F, 0xFD })) {
        return .{
            .id = .zstd,
            .category = .archive,
            .family = .none,
            .mime_type = "application/zstd",
            .extension = "zst",
            .description = "Zstandard Compressed Data",
        };
    }

    // 8. LZ4 Frame (04 22 4D 18)
    if (std.mem.eql(u8, buf[0..4], &.{ 0x04, 0x22, 0x4D, 0x18 })) {
        return .{
            .id = .lz4,
            .category = .archive,
            .family = .none,
            .mime_type = "application/x-lz4",
            .extension = "lz4",
            .description = "LZ4 Compressed Frame",
        };
    }

    // 9. Microsoft Cabinet Archive ("MSCF\x00\x00\x00\x00")
    if (buf.len >= 8 and std.mem.eql(u8, buf[0..8], "MSCF\x00\x00\x00\x00")) {
        return .{
            .id = .cab,
            .category = .archive,
            .family = .none,
            .mime_type = "application/vnd.ms-cab-compressed",
            .extension = "cab",
            .description = "Microsoft Cabinet Archive (CAB)",
        };
    }

    // 10. Unix Archiver / Debian Package ("!<arch>\n")
    if (buf.len >= 8 and std.mem.eql(u8, buf[0..8], "!<arch>\n")) {
        return .{
            .id = .ar_deb,
            .category = .archive,
            .family = .none,
            .mime_type = "application/x-archive",
            .extension = "ar",
            .description = "Unix Archiver (AR) / Debian Package",
        };
    }

    // 11. RPM Package (ED AB EE DB)
    if (std.mem.eql(u8, buf[0..4], &.{ 0xED, 0xAB, 0xEE, 0xDB })) {
        return .{
            .id = .rpm,
            .category = .archive,
            .family = .none,
            .mime_type = "application/x-rpm",
            .extension = "rpm",
            .description = "RPM Package Archive",
        };
    }

    // 12. POSIX TAR Archive ("ustar\x00" or "ustar  \x00" at offset 257)
    if (buf.len >= 265 and std.mem.eql(u8, buf[257..262], "ustar")) {
        return .{
            .id = .tar,
            .category = .archive,
            .family = .none,
            .mime_type = "application/x-tar",
            .extension = "tar",
            .description = "POSIX ustar Tape Archive (TAR)",
        };
    }

    return null;
}

/// Inspects the first ZIP Local File Header (30-byte fixed header + filename) to distinguish
/// standard ZIP archives from JAR/APK, EPUB, OOXML (`.docx`/`.xlsx`/`.pptx`), and ODF.
fn classifyZipContainer(buf: []const u8) MagicInfo {
    if (buf.len >= 30 and std.mem.eql(u8, buf[0..4], "PK\x03\x04")) {
        const name_len = std.mem.readInt(u16, buf[26..28], .little);
        const extra_len = std.mem.readInt(u16, buf[28..30], .little);
        const name_end: usize = 30 + @as(usize, name_len);
        if (name_len > 0 and name_end <= buf.len) {
            const first_name = buf[30..name_end];
            if (std.mem.eql(u8, first_name, "META-INF/MANIFEST.MF") or
                std.mem.startsWith(u8, first_name, "META-INF/") or
                std.mem.eql(u8, first_name, "AndroidManifest.xml") or
                std.mem.eql(u8, first_name, "classes.dex"))
            {
                return .{
                    .id = .jar_or_apk,
                    .category = .executable,
                    .family = .none,
                    .mime_type = "application/java-archive",
                    .extension = "jar",
                    .description = "Java Archive (JAR) or Android Package (APK)",
                };
            }
            if (std.mem.eql(u8, first_name, "[Content_Types].xml") or
                std.mem.startsWith(u8, first_name, "word/") or
                std.mem.startsWith(u8, first_name, "xl/") or
                std.mem.startsWith(u8, first_name, "ppt/") or
                std.mem.startsWith(u8, first_name, "_rels/"))
            {
                return .{
                    .id = .ooxml,
                    .category = .document,
                    .family = .none,
                    .mime_type = "application/vnd.openxmlformats-officedocument",
                    .extension = "docx",
                    .description = "Office Open XML Document (OOXML ZIP)",
                };
            }
            if (std.mem.eql(u8, first_name, "mimetype")) {
                const data_start = name_end + @as(usize, extra_len);
                if (data_start < buf.len) {
                    const payload = buf[data_start..];
                    if (std.mem.startsWith(u8, payload, "application/epub+zip")) {
                        return .{
                            .id = .epub,
                            .category = .document,
                            .family = .none,
                            .mime_type = "application/epub+zip",
                            .extension = "epub",
                            .description = "EPUB Electronic Publication",
                        };
                    }
                    if (std.mem.startsWith(u8, payload, "application/vnd.oasis.opendocument")) {
                        return .{
                            .id = .odf,
                            .category = .document,
                            .family = .none,
                            .mime_type = "application/vnd.oasis.opendocument.text",
                            .extension = "odt",
                            .description = "OpenDocument Format Archive (ODF)",
                        };
                    }
                }
            }
        }
    }

    return .{
        .id = .zip,
        .category = .archive,
        .family = .none,
        .mime_type = "application/zip",
        .extension = "zip",
        .description = "ZIP Archive",
    };
}
