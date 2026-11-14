const std = @import("std");
const types = @import("types.zig");
const MagicInfo = types.MagicInfo;

/// Detects multimedia containers (`ISOBMFF`, `EBML`, `RIFF`, `MPEG-TS`, `OGG`, `FLV`, `ASF`, `MPEG-PS`)
/// and elementary audio/video streams anchored at physical byte offset `0x00`.
pub fn detect(buf: []const u8) ?MagicInfo {
    if (buf.len < 4) return null;

    // 1. EBML / Matroska / WebM (RFC 8794: 1A 45 DF A3 at 0x00..0x04)
    if (std.mem.eql(u8, buf[0..4], &.{ 0x1A, 0x45, 0xDF, 0xA3 })) {
        return classifyEbml(buf);
    }

    // 2. RIFF / RIFX Container ("RIFF" or "RIFX" at 0x00..0x04, Form Type at 0x08..0x0C)
    if (buf.len >= 12 and (std.mem.eql(u8, buf[0..4], "RIFF") or std.mem.eql(u8, buf[0..4], "RIFX"))) {
        if (classifyRiff(buf)) |info| return info;
    }

    // 3. ISOBMFF (MP4, MOV, M4V, M4A, 3GP, HEIC, AVIF, JP2 — ISO/IEC 14496-12 at 0x00..0x08)
    if (buf.len >= 8) {
        if (classifyIsobmff(buf)) |info| return info;
    }

    // 4. Ogg Container ("OggS" at 0x00..0x04)
    if (std.mem.eql(u8, buf[0..4], "OggS")) {
        return classifyOgg(buf);
    }

    // 5. Flash Video ("FLV\x01" at 0x00..0x04)
    if (std.mem.eql(u8, buf[0..4], "FLV\x01")) {
        return .{
            .id = .flv,
            .category = .video,
            .family = .flv,
            .mime_type = "video/x-flv",
            .extension = "flv",
            .description = "Adobe Flash Video Container (FLV)",
        };
    }

    // 6. MPEG-2 Program Stream (00 00 01 BA) & MPEG Elementary Video Stream (00 00 01 B3)
    if (std.mem.eql(u8, buf[0..4], &.{ 0x00, 0x00, 0x01, 0xBA })) {
        return .{
            .id = .mpeg_ps,
            .category = .video,
            .family = .mpeg_ps,
            .mime_type = "video/mpeg",
            .extension = "mpg",
            .description = "MPEG-2 Program Stream (PS)",
        };
    }
    if (std.mem.eql(u8, buf[0..4], &.{ 0x00, 0x00, 0x01, 0xB3 })) {
        return .{
            .id = .mpeg_es,
            .category = .video,
            .family = .mpeg_ps,
            .mime_type = "video/mpeg",
            .extension = "mpg",
            .description = "MPEG Video Elementary Stream",
        };
    }

    // 7. Microsoft ASF / WMV / WMA (16-byte GUID at 0x00..0x10)
    if (buf.len >= 16 and std.mem.eql(
        u8,
        buf[0..16],
        &.{ 0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C },
    )) {
        return .{
            .id = .asf_wmv,
            .category = .video,
            .family = .asf,
            .mime_type = "video/x-ms-asf",
            .extension = "wmv",
            .description = "Microsoft Advanced Systems Format (ASF/WMV)",
        };
    }

    // 8. MPEG-2 Transport Stream (188-byte TS or 192-byte M2TS periodic 0x47 sync byte)
    if (classifyMpegTs(buf)) |info| return info;

    // 9. Audio Formats: FLAC ("fLaC"), AIFF ("FORM".."AIFF"), MIDI ("MThd"), AMR ("#!AMR"), MP3, AAC ADTS
    if (std.mem.eql(u8, buf[0..4], "fLaC")) {
        return .{
            .id = .flac,
            .category = .audio,
            .family = .none,
            .mime_type = "audio/flac",
            .extension = "flac",
            .description = "Free Lossless Audio Codec (FLAC)",
        };
    }

    if (buf.len >= 12 and std.mem.eql(u8, buf[0..4], "FORM") and
        (std.mem.eql(u8, buf[8..12], "AIFF") or std.mem.eql(u8, buf[8..12], "AIFC")))
    {
        return .{
            .id = .aiff,
            .category = .audio,
            .family = .none,
            .mime_type = "audio/aiff",
            .extension = "aiff",
            .description = "Audio Interchange File Format (AIFF)",
        };
    }

    if (std.mem.eql(u8, buf[0..4], "MThd")) {
        return .{
            .id = .midi,
            .category = .audio,
            .family = .none,
            .mime_type = "audio/midi",
            .extension = "mid",
            .description = "Standard MIDI Audio File",
        };
    }

    if (buf.len >= 5 and std.mem.eql(u8, buf[0..5], "#!AMR")) {
        return .{
            .id = .amr,
            .category = .audio,
            .family = .none,
            .mime_type = "audio/amr",
            .extension = "amr",
            .description = "Adaptive Multi-Rate Audio (AMR)",
        };
    }

    if (std.mem.eql(u8, buf[0..3], "ID3")) {
        return .{
            .id = .mp3,
            .category = .audio,
            .family = .none,
            .mime_type = "audio/mpeg",
            .extension = "mp3",
            .description = "MPEG Audio Stream with ID3v2 Tag (MP3)",
        };
    }

    // AAC ADTS Syncword (0xFFF0 mask with layer == 00) vs MPEG Audio Frame Sync (MP3)
    if (buf[0] == 0xFF and (buf[1] & 0xF6) == 0xF0) {
        return .{
            .id = .aac_adts,
            .category = .audio,
            .family = .none,
            .mime_type = "audio/aac",
            .extension = "aac",
            .description = "Advanced Audio Coding ADTS Stream (AAC)",
        };
    }
    if (buf[0] == 0xFF and (buf[1] & 0xE6) == 0xE2 and (buf[2] & 0xF0) != 0xF0 and (buf[2] & 0x0C) != 0x0C) {
        return .{
            .id = .mp3,
            .category = .audio,
            .family = .none,
            .mime_type = "audio/mpeg",
            .extension = "mp3",
            .description = "MPEG-1/2 Layer III Audio Stream (MP3)",
        };
    }

    return null;
}

/// Validates and disambiguates ISO Base Media File Format (`ISO/IEC 14496-12`) headers at offset `0x00`.
fn classifyIsobmff(buf: []const u8) ?MagicInfo {
    const box_size = std.mem.readInt(u32, buf[0..4], .big);
    const box_type = buf[4..8];

    if (std.mem.eql(u8, box_type, "ftyp") or std.mem.eql(u8, box_type, "styp")) {
        // Per ISO/IEC 14496-12 Clause 4.3: an ftyp box must be at least 16 bytes
        // (8-byte header + 4-byte major_brand + 4-byte minor_version) and a multiple of 4 bytes.
        if (box_size < 16 or (box_size % 4) != 0) return null;

        if (buf.len >= 12) {
            const major = buf[8..12];
            if (classifyIsobmffBrand(major)) |info| return info;

            // Inspect compatible_brands starting at offset 16 if major_brand is generic
            const limit = @min(buf.len, @min(@as(usize, box_size), 64));
            var off: usize = 16;
            while (off + 4 <= limit) : (off += 4) {
                if (classifyIsobmffBrand(buf[off .. off + 4])) |info| return info;
            }
        }

        return mp4DefaultInfo();
    }

    // Legacy QuickTime or fragmented ISOBMFF streams starting with a valid root atom
    if (std.mem.eql(u8, box_type, "moov") or
        std.mem.eql(u8, box_type, "wide") or
        std.mem.eql(u8, box_type, "mdat") or
        std.mem.eql(u8, box_type, "free") or
        std.mem.eql(u8, box_type, "skip") or
        std.mem.eql(u8, box_type, "pdin"))
    {
        if (box_size >= 8 or box_size == 1 or (box_size == 0 and std.mem.eql(u8, box_type, "mdat"))) {
            return mp4DefaultInfo();
        }
    }

    return null;
}

fn classifyIsobmffBrand(brand: []const u8) ?MagicInfo {
    // 1. Apple QuickTime (.mov)
    if (std.mem.eql(u8, brand, "qt  ")) {
        return .{
            .id = .mov,
            .category = .video,
            .family = .isobmff,
            .mime_type = "video/quicktime",
            .extension = "mov",
            .description = "Apple QuickTime Movie Container (ISOBMFF/MOV)",
        };
    }

    // 2. Apple M4A Audio (.m4a / .m4b / .m4p)
    if (std.mem.eql(u8, brand, "M4A ") or std.mem.eql(u8, brand, "M4B ") or std.mem.eql(u8, brand, "M4P ")) {
        return .{
            .id = .m4a,
            .category = .audio,
            .family = .isobmff,
            .mime_type = "audio/mp4",
            .extension = "m4a",
            .description = "MPEG-4 Audio Container (M4A)",
        };
    }

    // 3. Apple M4V Video (.m4v)
    if (std.mem.eql(u8, brand, "M4V ") or std.mem.eql(u8, brand, "M4VH") or std.mem.eql(u8, brand, "M4VP")) {
        return .{
            .id = .m4v,
            .category = .video,
            .family = .isobmff,
            .mime_type = "video/x-m4v",
            .extension = "m4v",
            .description = "Apple MPEG-4 Video Container (M4V)",
        };
    }

    // 4. Adobe Flash MP4 (.f4v)
    if (std.mem.eql(u8, brand, "f4v ") or std.mem.eql(u8, brand, "f4p ") or std.mem.eql(u8, brand, "F4V ")) {
        return .{
            .id = .f4v,
            .category = .video,
            .family = .isobmff,
            .mime_type = "video/x-f4v",
            .extension = "f4v",
            .description = "Adobe Flash MP4 Video Container (F4V)",
        };
    }

    // 5. 3GPP2 (.3g2) & 3GPP (.3gp)
    if (std.mem.startsWith(u8, brand, "3g2")) {
        return .{
            .id = .@"3g2",
            .category = .video,
            .family = .isobmff,
            .mime_type = "video/3gpp2",
            .extension = "3g2",
            .description = "3GPP2 Multimedia Container (3G2)",
        };
    }
    if (std.mem.startsWith(u8, brand, "3gp") or
        std.mem.eql(u8, brand, "3ge6") or
        std.mem.eql(u8, brand, "3gg6") or
        std.mem.eql(u8, brand, "3gr6") or
        std.mem.eql(u8, brand, "3gs6"))
    {
        return .{
            .id = .@"3gp",
            .category = .video,
            .family = .isobmff,
            .mime_type = "video/3gpp",
            .extension = "3gp",
            .description = "3GPP Multimedia Container (3GP)",
        };
    }

    // 6. ISOBMFF Still Images (HEIC, HEIF, AVIF, JP2, Canon CR3)
    if (std.mem.eql(u8, brand, "heic") or
        std.mem.eql(u8, brand, "heix") or
        std.mem.eql(u8, brand, "heim") or
        std.mem.eql(u8, brand, "heis") or
        std.mem.eql(u8, brand, "hevc") or
        std.mem.eql(u8, brand, "hevx"))
    {
        return .{
            .id = .heic,
            .category = .image,
            .family = .isobmff,
            .mime_type = "image/heic",
            .extension = "heic",
            .description = "High Efficiency Image File Format (HEIC)",
        };
    }
    if (std.mem.eql(u8, brand, "mif1") or std.mem.eql(u8, brand, "msf1")) {
        return .{
            .id = .heif,
            .category = .image,
            .family = .isobmff,
            .mime_type = "image/heif",
            .extension = "heif",
            .description = "High Efficiency Image File Format (HEIF)",
        };
    }
    if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) {
        return .{
            .id = .avif,
            .category = .image,
            .family = .isobmff,
            .mime_type = "image/avif",
            .extension = "avif",
            .description = "AV1 Image File Format (AVIF)",
        };
    }
    if (std.mem.eql(u8, brand, "jp2 ") or std.mem.eql(u8, brand, "jpx ") or std.mem.eql(u8, brand, "jpm ")) {
        return .{
            .id = .jp2,
            .category = .image,
            .family = .isobmff,
            .mime_type = "image/jp2",
            .extension = "jp2",
            .description = "JPEG 2000 Image (JP2)",
        };
    }
    if (std.mem.eql(u8, brand, "crx ")) {
        return .{
            .id = .cr3,
            .category = .image,
            .family = .isobmff,
            .mime_type = "image/x-canon-cr3",
            .extension = "cr3",
            .description = "Canon RAW v3 Image (CR3)",
        };
    }

    // 7. Standard MP4 brands (isom, iso2..iso9, mp41, mp42, avc1, dash, MP4 , msdh, msix, XAVC)
    if (std.mem.eql(u8, brand, "isom") or
        std.mem.startsWith(u8, brand, "iso") or
        std.mem.startsWith(u8, brand, "mp4") or
        std.mem.eql(u8, brand, "avc1") or
        std.mem.eql(u8, brand, "dash") or
        std.mem.eql(u8, brand, "MP4 ") or
        std.mem.eql(u8, brand, "msdh") or
        std.mem.eql(u8, brand, "msix") or
        std.mem.eql(u8, brand, "XAVC"))
    {
        return mp4DefaultInfo();
    }

    return null;
}

fn mp4DefaultInfo() MagicInfo {
    return .{
        .id = .mp4,
        .category = .video,
        .family = .isobmff,
        .mime_type = "video/mp4",
        .extension = "mp4",
        .description = "ISO Base Media File Format / MPEG-4 Video (MP4)",
    };
}

/// Inspects an EBML header (`1A 45 DF A3`) for the `DocType` element (`0x42 0x82`) to distinguish
/// `video/webm` (`.webm`) from `video/x-matroska` (`.mkv`).
fn classifyEbml(buf: []const u8) MagicInfo {
    const scan_limit = @min(buf.len, 128);
    var i: usize = 4;
    while (i + 3 < scan_limit) : (i += 1) {
        if (buf[i] == 0x42 and buf[i + 1] == 0x82) {
            const vint_byte = buf[i + 2];
            if (vint_byte >= 0x81 and vint_byte <= 0x9F) {
                const doc_len: usize = vint_byte & 0x7F;
                const doc_start = i + 3;
                const doc_end = doc_start + doc_len;
                if (doc_end <= buf.len) {
                    const doctype = std.mem.trimEnd(u8, buf[doc_start..doc_end], "\x00");
                    if (std.mem.eql(u8, doctype, "webm")) {
                        return .{
                            .id = .webm,
                            .category = .video,
                            .family = .ebml,
                            .mime_type = "video/webm",
                            .extension = "webm",
                            .description = "WebM Multimedia Container (EBML)",
                        };
                    }
                    if (std.mem.eql(u8, doctype, "matroska")) {
                        break;
                    }
                }
            }
        }
    }

    return .{
        .id = .mkv,
        .category = .video,
        .family = .ebml,
        .mime_type = "video/x-matroska",
        .extension = "mkv",
        .description = "Matroska Multimedia Container (EBML/MKV)",
    };
}

/// Inspects the 4-byte RIFF Form Type at `buf[8..12]`.
fn classifyRiff(buf: []const u8) ?MagicInfo {
    const form = buf[8..12];
    if (std.mem.eql(u8, form, "AVI ") or std.mem.eql(u8, form, "AVIX")) {
        return .{
            .id = .avi,
            .category = .video,
            .family = .riff,
            .mime_type = "video/x-msvideo",
            .extension = "avi",
            .description = "Audio Video Interleave Container (RIFF/AVI)",
        };
    }
    if (std.mem.eql(u8, form, "WAVE")) {
        return .{
            .id = .wav,
            .category = .audio,
            .family = .riff,
            .mime_type = "audio/vnd.wave",
            .extension = "wav",
            .description = "Waveform Audio File Format (RIFF/WAV)",
        };
    }
    if (std.mem.eql(u8, form, "WEBP")) {
        return .{
            .id = .webp,
            .category = .image,
            .family = .riff,
            .mime_type = "image/webp",
            .extension = "webp",
            .description = "WebP Image Container (RIFF/WEBP)",
        };
    }
    if (std.mem.eql(u8, form, "ACON")) {
        return .{
            .id = .ani,
            .category = .image,
            .family = .riff,
            .mime_type = "application/x-navi-animation",
            .extension = "ani",
            .description = "Windows Animated Cursor (RIFF/ACON)",
        };
    }
    if (std.mem.eql(u8, form, "RMID")) {
        return .{
            .id = .midi,
            .category = .audio,
            .family = .riff,
            .mime_type = "audio/midi",
            .extension = "rmi",
            .description = "RIFF Musical Instrument Digital Interface (RMID)",
        };
    }
    return null;
}

/// Inspects the first Ogg page (`OggS`) to distinguish Ogg Theora/Video (`.ogv`), Ogg Opus (`.opus`), and Ogg Audio (`.ogg`).
fn classifyOgg(buf: []const u8) MagicInfo {
    if (buf.len >= 36) {
        const page_segments: usize = buf[26];
        const payload_start: usize = 27 + page_segments;
        if (payload_start + 8 <= buf.len) {
            const payload = buf[payload_start..@min(buf.len, payload_start + 16)];
            if (std.mem.startsWith(u8, payload, "\x80theora") or
                std.mem.startsWith(u8, payload, "\x01video") or
                std.mem.startsWith(u8, payload, "BBCD\x00"))
            {
                return .{
                    .id = .ogv,
                    .category = .video,
                    .family = .ogg,
                    .mime_type = "video/ogg",
                    .extension = "ogv",
                    .description = "Ogg Video Container (Theora/Dirac/OGV)",
                };
            }
            if (std.mem.startsWith(u8, payload, "OpusHead")) {
                return .{
                    .id = .opus,
                    .category = .audio,
                    .family = .ogg,
                    .mime_type = "audio/opus",
                    .extension = "opus",
                    .description = "Ogg Opus Audio Stream",
                };
            }
        }
    }

    return .{
        .id = .ogg,
        .category = .audio,
        .family = .ogg,
        .mime_type = "audio/ogg",
        .extension = "ogg",
        .description = "Ogg Multimedia Container",
    };
}

/// Verifies periodic `0x47` sync bytes for MPEG-2 Transport Stream (188-byte stride),
/// DVB-T FEC MPEG-2 Transport Stream (204-byte stride), and BDAV M2TS (192-byte stride).
fn classifyMpegTs(buf: []const u8) ?MagicInfo {
    // 1. Standard 188-byte MPEG-TS (checks 0, 188, and 376 / 564 when within buffer bounds)
    if (buf.len >= 189 and buf[0] == 0x47 and buf[188] == 0x47) {
        if ((buf.len < 377 or buf[376] == 0x47) and (buf.len < 565 or buf[564] == 0x47)) {
            return .{
                .id = .mpeg_ts,
                .category = .video,
                .family = .mpeg_ts,
                .mime_type = "video/mp2t",
                .extension = "ts",
                .description = "MPEG-2 Transport Stream (188-byte packets)",
            };
        }
    }

    // 2. DVB-T 204-byte MPEG-TS (188-byte TS + 16-byte Reed-Solomon FEC, sync at 0, 204, 408, 612)
    if (buf.len >= 205 and buf[0] == 0x47 and buf[204] == 0x47) {
        if ((buf.len < 409 or buf[408] == 0x47) and (buf.len < 613 or buf[612] == 0x47)) {
            return .{
                .id = .mpeg_ts,
                .category = .video,
                .family = .mpeg_ts,
                .mime_type = "video/mp2t",
                .extension = "ts",
                .description = "MPEG-2 Transport Stream (204-byte FEC packets)",
            };
        }
    }

    // 3. Blu-ray BDAV M2TS (4-byte timestamp + 188-byte TS packet = 192-byte stride, sync at 4, 196, 388, 580)
    if (buf.len >= 197 and buf[4] == 0x47 and buf[196] == 0x47) {
        if ((buf.len < 389 or buf[388] == 0x47) and (buf.len < 581 or buf[580] == 0x47)) {
            return .{
                .id = .m2ts,
                .category = .video,
                .family = .mpeg_ts,
                .mime_type = "video/mp2t",
                .extension = "m2ts",
                .description = "BDAV MPEG-2 Transport Stream (192-byte M2TS)",
            };
        }
    }

    return null;
}
