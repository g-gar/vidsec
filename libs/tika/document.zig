const std = @import("std");
const types = @import("types.zig");
const MagicInfo = types.MagicInfo;

/// Detects documents, databases, packet captures, shell scripts, and network manifests at offset `0x00`.
pub fn detect(buf: []const u8) ?MagicInfo {
    if (buf.len < 2) return null;

    // 1. Unix Shebang Script ("#!" at 0x00, excluding "#!AMR" audio streams)
    if (buf[0] == '#' and buf[1] == '!') {
        if (buf.len >= 5 and std.mem.eql(u8, buf[0..5], "#!AMR")) {
            return null; // Handled by media.zig
        }
        return .{
            .id = .shebang_script,
            .category = .script,
            .family = .none,
            .mime_type = "text/x-script",
            .extension = "sh",
            .description = "Unix Shebang Interpreter Script (#!)",
        };
    }

    if (buf.len < 4) return null;

    // 2. HLS M3U8 Network Playlist ("#EXTM3U" at 0x00 — SSRF / External Reference Vector)
    if (buf.len >= 7 and std.mem.eql(u8, buf[0..7], "#EXTM3U")) {
        return .{
            .id = .m3u8_playlist,
            .category = .manifest,
            .family = .none,
            .mime_type = "application/vnd.apple.mpegurl",
            .extension = "m3u8",
            .description = "HTTP Live Streaming Playlist Manifest (M3U8)",
        };
    }

    // 3. Adobe PDF Document ("%PDF-" at 0x00..0x05)
    if (buf.len >= 5 and std.mem.eql(u8, buf[0..5], "%PDF-")) {
        return .{
            .id = .pdf,
            .category = .document,
            .family = .none,
            .mime_type = "application/pdf",
            .extension = "pdf",
            .description = "PDF Document",
        };
    }

    // 4. Microsoft Compound File Binary Format / OLE2 (D0 CF 11 E0 A1 B1 1A E1)
    if (buf.len >= 8 and std.mem.eql(u8, buf[0..8], &.{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 })) {
        return .{
            .id = .ole2,
            .category = .document,
            .family = .none,
            .mime_type = "application/x-ole-storage",
            .extension = "doc",
            .description = "Microsoft Compound File Binary (OLE2 / Legacy Office / MSI)",
        };
    }

    // 5. Rich Text Format ("{\\rtf")
    if (buf.len >= 5 and std.mem.eql(u8, buf[0..5], "{\\rtf")) {
        return .{
            .id = .rtf,
            .category = .document,
            .family = .none,
            .mime_type = "application/rtf",
            .extension = "rtf",
            .description = "Rich Text Format Document (RTF)",
        };
    }

    // 6. SQLite 3 Database ("SQLite format 3\x00" at 0x00..0x10)
    if (buf.len >= 16 and std.mem.eql(u8, buf[0..16], "SQLite format 3\x00")) {
        return .{
            .id = .sqlite3,
            .category = .database,
            .family = .none,
            .mime_type = "application/vnd.sqlite3",
            .extension = "sqlite",
            .description = "SQLite 3.x Database File",
        };
    }

    // 7. Libpcap / PCAPNG Network Capture
    const magic_be = std.mem.readInt(u32, buf[0..4], .big);
    if (magic_be == 0xA1B2C3D4 or magic_be == 0xD4C3B2A1 or magic_be == 0xA1B23C4D or magic_be == 0x4D3CB2A1) {
        return .{
            .id = .pcap,
            .category = .database,
            .family = .none,
            .mime_type = "application/vnd.tcpdump.pcap",
            .extension = "pcap",
            .description = "Libpcap Network Packet Capture",
        };
    }
    if (magic_be == 0x0A0D0D0A and buf.len >= 12 and std.mem.eql(u8, buf[8..12], &.{ 0x4D, 0x3C, 0x2B, 0x1A })) {
        return .{
            .id = .pcapng,
            .category = .database,
            .family = .none,
            .mime_type = "application/x-pcapng",
            .extension = "pcapng",
            .description = "PCAP Next Generation Packet Capture (PCAPNG)",
        };
    }

    // 8. Structured Markup, Scripts & Manifests (`<ASX`, `<?php`, `<svg`, `<!DOCTYPE html`, `<html`, `<script`, `<?xml`)
    return detectMarkupOrScript(buf);
}

fn detectMarkupOrScript(buf: []const u8) ?MagicInfo {
    const trimmed = trimLeadingAsciiWhitespaceAndBom(buf[0..@min(buf.len, 256)]);
    if (trimmed.len < 4 or trimmed[0] != '<') return null;

    if (startsWithIgnoreCase(trimmed, "<asx")) {
        return .{
            .id = .asx_playlist,
            .category = .manifest,
            .family = .none,
            .mime_type = "video/x-ms-asf",
            .extension = "asx",
            .description = "Advanced Stream Redirector Manifest (ASX)",
        };
    }

    if (startsWithIgnoreCase(trimmed, "<?php")) {
        return .{
            .id = .php_script,
            .category = .script,
            .family = .none,
            .mime_type = "application/x-httpd-php",
            .extension = "php",
            .description = "PHP Script",
        };
    }

    if (startsWithIgnoreCase(trimmed, "<svg")) {
        return .{
            .id = .svg,
            .category = .image,
            .family = .none,
            .mime_type = "image/svg+xml",
            .extension = "svg",
            .description = "Scalable Vector Graphics (SVG XML)",
        };
    }

    if (startsWithIgnoreCase(trimmed, "<!doctype html") or
        startsWithIgnoreCase(trimmed, "<html") or
        startsWithIgnoreCase(trimmed, "<head") or
        startsWithIgnoreCase(trimmed, "<script"))
    {
        return .{
            .id = .html_doc,
            .category = .script,
            .family = .none,
            .mime_type = "text/html",
            .extension = "html",
            .description = "HTML Document / Web Script",
        };
    }

    if (startsWithIgnoreCase(trimmed, "<?xml")) {
        if (containsIgnoreCase(trimmed, "<svg")) {
            return .{
                .id = .svg,
                .category = .image,
                .family = .none,
                .mime_type = "image/svg+xml",
                .extension = "svg",
                .description = "Scalable Vector Graphics (SVG XML)",
            };
        }
        return .{
            .id = .xml_doc,
            .category = .document,
            .family = .none,
            .mime_type = "application/xml",
            .extension = "xml",
            .description = "XML Document",
        };
    }

    return null;
}

fn trimLeadingAsciiWhitespaceAndBom(slice: []const u8) []const u8 {
    var s = slice;
    // Strip UTF-8 BOM (EF BB BF) if present
    if (s.len >= 3 and s[0] == 0xEF and s[1] == 0xBB and s[2] == 0xBF) {
        s = s[3..];
    }
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) : (i += 1) {}
    return s[i..];
}

fn startsWithIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (haystack.len < needle_lower.len) return false;
    for (haystack[0..needle_lower.len], needle_lower) |h, n| {
        if (std.ascii.toLower(h) != n) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (haystack.len < needle_lower.len) return false;
    const limit = haystack.len - needle_lower.len;
    var i: usize = 0;
    while (i <= limit) : (i += 1) {
        if (startsWithIgnoreCase(haystack[i..], needle_lower)) return true;
    }
    return false;
}
