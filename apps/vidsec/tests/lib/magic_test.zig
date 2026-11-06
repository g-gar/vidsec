const std = @import("std");
const magic = @import("vidsec_magic");

const FormatId = magic.FormatId;
const ContainerFamily = magic.ContainerFamily;
const Category = magic.Category;
const detect = magic.detect;
const findFirstEmbeddedSignature = magic.findFirstEmbeddedSignature;

test "Video container detection: ISOBMFF (MP4, MOV, M4V, 3GP, 3G2, F4V), EBML (MKV, WebM), RIFF (AVI), MPEG-TS, FLV, OGV" {
    // 1. MP4 (ftyp isom)
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    const mp4 = detect(mp4_hdr);
    try std.testing.expect(mp4.isVideo());
    try std.testing.expect(mp4.isSupportedVideoContainer());
    try std.testing.expectEqual(FormatId.mp4, mp4.id);
    try std.testing.expectEqual(ContainerFamily.isobmff, mp4.family);
    try std.testing.expectEqualStrings("video/mp4", mp4.mime_type);
    try std.testing.expectEqualStrings("mp4", mp4.extension);
    try std.testing.expectEqual(@as(i64, 1), mp4.kindCode());

    // 2. QuickTime MOV (ftyp qt  )
    const mov_hdr = "\x00\x00\x00\x14ftypqt  \x20\x05\x03\x00qt  ";
    const mov = detect(mov_hdr);
    try std.testing.expect(mov.isVideo());
    try std.testing.expectEqual(FormatId.mov, mov.id);
    try std.testing.expectEqual(ContainerFamily.isobmff, mov.family);
    try std.testing.expectEqualStrings("video/quicktime", mov.mime_type);

    // 3. 3GPP (.3gp)
    const gp3_hdr = "\x00\x00\x00\x14ftyp3gp5\x00\x00\x01\x003gp5";
    const gp3 = detect(gp3_hdr);
    try std.testing.expect(gp3.isVideo());
    try std.testing.expectEqual(FormatId.@"3gp", gp3.id);
    try std.testing.expectEqualStrings("video/3gpp", gp3.mime_type);

    // 4. Matroska (.mkv) vs WebM (.webm) via EBML DocType
    const mkv_hdr = "\x1A\x45\xDF\xA3\x9F\x42\x86\x81\x01\x42\xF7\x81\x01\x42\x82\x88matroska\x42\x87\x81\x04";
    const mkv = detect(mkv_hdr);
    try std.testing.expect(mkv.isVideo());
    try std.testing.expectEqual(FormatId.mkv, mkv.id);
    try std.testing.expectEqual(ContainerFamily.ebml, mkv.family);
    try std.testing.expectEqualStrings("video/x-matroska", mkv.mime_type);

    const webm_hdr = "\x1A\x45\xDF\xA3\x9F\x42\x86\x81\x01\x42\x82\x84webm\x42\x87\x81\x02";
    const webm = detect(webm_hdr);
    try std.testing.expect(webm.isVideo());
    try std.testing.expectEqual(FormatId.webm, webm.id);
    try std.testing.expectEqual(ContainerFamily.ebml, webm.family);
    try std.testing.expectEqualStrings("video/webm", webm.mime_type);

    // 5. RIFF AVI (.avi)
    const avi_hdr = "RIFF\x00\x10\x00\x00AVI LIST";
    const avi = detect(avi_hdr);
    try std.testing.expect(avi.isVideo());
    try std.testing.expectEqual(FormatId.avi, avi.id);
    try std.testing.expectEqual(ContainerFamily.riff, avi.family);
    try std.testing.expectEqualStrings("video/x-msvideo", avi.mime_type);

    // 6. MPEG-TS (188-byte sync 0x47 at 0, 188, 376)
    var ts_buf: [380]u8 = @splat(0x00);
    ts_buf[0] = 0x47;
    ts_buf[188] = 0x47;
    ts_buf[376] = 0x47;
    const ts = detect(&ts_buf);
    try std.testing.expect(ts.isVideo());
    try std.testing.expectEqual(FormatId.mpeg_ts, ts.id);
    try std.testing.expectEqual(ContainerFamily.mpeg_ts, ts.family);
    try std.testing.expectEqualStrings("video/mp2t", ts.mime_type);

    // 7. FLV and Ogg Theora (.ogv)
    const flv = detect("FLV\x01\x05\x00\x00\x00\x09");
    try std.testing.expect(flv.isVideo());
    try std.testing.expectEqual(FormatId.flv, flv.id);
    try std.testing.expectEqualStrings("video/x-flv", flv.mime_type);
}

test "Non-video media & assets inside shared containers (M4A, WAV, WebP, HEIC, AVIF)" {
    // M4A is audio/mp4 (.isVideo() == false, .isAudio() == true)
    const m4a_hdr = "\x00\x00\x00\x14ftypM4A \x00\x00\x00\x00M4A ";
    const m4a = detect(m4a_hdr);
    try std.testing.expect(!m4a.isVideo());
    try std.testing.expect(m4a.isAudio());
    try std.testing.expectEqual(FormatId.m4a, m4a.id);
    try std.testing.expectEqualStrings("audio/mp4", m4a.mime_type);

    // HEIC & AVIF inside ISOBMFF are images (.isVideo() == false, .isSafeAttachment() == true)
    const heic_hdr = "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic";
    const heic = detect(heic_hdr);
    try std.testing.expect(!heic.isVideo());
    try std.testing.expectEqual(Category.image, heic.category);
    try std.testing.expect(heic.isSafeAttachment());
    try std.testing.expectEqualStrings("image/heic", heic.mime_type);

    const avif_hdr = "\x00\x00\x00\x18ftypavif\x00\x00\x00\x00mif1avif";
    const avif = detect(avif_hdr);
    try std.testing.expect(!avif.isVideo());
    try std.testing.expectEqual(FormatId.avif, avif.id);
    try std.testing.expectEqualStrings("image/avif", avif.mime_type);

    // RIFF WAVE (audio) and RIFF WEBP (image)
    const wav = detect("RIFF\x24\x08\x00\x00WAVEfmt ");
    try std.testing.expect(!wav.isVideo());
    try std.testing.expect(wav.isAudio());
    try std.testing.expectEqualStrings("audio/vnd.wave", wav.mime_type);

    const webp = detect("RIFF\x24\x08\x00\x00WEBPVP8 ");
    try std.testing.expect(!webp.isVideo());
    try std.testing.expectEqual(Category.image, webp.category);
    try std.testing.expect(webp.isSafeAttachment());
    try std.testing.expectEqualStrings("image/webp", webp.mime_type);
}

test "R01 Security Invariants: Hostile-First Priority, Displaced Polyglot Rejection, and CAFEBABE Disambiguation" {
    // 1. Chameleon / Polyglot: starts with "MZ" at 0x00, AND bytes 4..8 happen to spell "ftyp" or "free"!
    // Must be classified unconditionally as an executable (MZ/PE), NEVER as ISOBMFF!
    const mz_polyglot = "MZ\x00\x18ftypisom\x00\x00\x02\x00isom";
    const mz_res = detect(mz_polyglot);
    try std.testing.expect(!mz_res.isVideo());
    try std.testing.expect(mz_res.isHostileInMedia());
    try std.testing.expectEqual(Category.executable, mz_res.category);
    try std.testing.expectEqual(FormatId.dos_mz, mz_res.id);
    try std.testing.expect(mz_res.kindCode() >= 10);

    // Full Windows PE with e_lfanew at 0x3C pointing to "PE\0\0" at 0x40
    var pe_buf: [72]u8 = @splat(0x00);
    pe_buf[0] = 'M';
    pe_buf[1] = 'Z';
    std.mem.writeInt(u32, pe_buf[0x3C..0x40], 0x40, .little);
    @memcpy(pe_buf[0x40..0x44], "PE\x00\x00");
    const pe_res = detect(&pe_buf);
    try std.testing.expectEqual(FormatId.pe_exe, pe_res.id);
    try std.testing.expectEqualStrings("application/vnd.microsoft.portable-executable", pe_res.mime_type);

    // 2. Displaced-Header Polyglot: 16 junk bytes followed by a valid MP4 ftyp box
    // Must return UNKNOWN (no forward scanning allowed).
    const displaced_mp4 = "0123456789ABCDEF\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isom";
    const displaced_res = detect(displaced_mp4);
    try std.testing.expect(!displaced_res.isVideo());
    try std.testing.expectEqual(FormatId.unknown, displaced_res.id);

    // 3. CAFEBABE Disambiguation: Mach-O Fat Binary (nfat_arch = 2) vs Java .class (major_version = 55 / Java 11)
    const macho_fat = detect(&.{ 0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02 });
    try std.testing.expectEqual(FormatId.macho_fat, macho_fat.id);
    try std.testing.expectEqualStrings("application/x-mach-binary", macho_fat.mime_type);

    const java_cls = detect(&.{ 0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x37 });
    try std.testing.expectEqual(FormatId.java_class, java_cls.id);
    try std.testing.expectEqualStrings("application/java-vm", java_cls.mime_type);
}

test "Archives, Documents, Fonts, Scripts, and Sliding-Window Signature Scanner (R06 & R07)" {
    // 1. Fonts & Images for R06 Attachment Validation
    const ttf = detect(&.{ 0x00, 0x01, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x80 });
    try std.testing.expect(ttf.isSafeAttachment());
    try std.testing.expectEqualStrings("font/ttf", ttf.mime_type);

    const woff2 = detect("wOF2\x00\x01\x00\x00");
    try std.testing.expect(woff2.isSafeAttachment());
    try std.testing.expectEqualStrings("font/woff2", woff2.mime_type);

    const png = detect(&.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });
    try std.testing.expect(png.isSafeAttachment());
    try std.testing.expectEqualStrings("image/png", png.mime_type);

    // SVG is an image, but carries active script risk so isSafeAttachment() MUST be false!
    const svg = detect("<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>");
    try std.testing.expectEqual(FormatId.svg, svg.id);
    try std.testing.expect(!svg.isSafeAttachment());
    try std.testing.expect(svg.isHostileInMedia());

    // 2. TAR at offset 257
    var tar_buf: [300]u8 = @splat(0x00);
    @memcpy(tar_buf[257..263], "ustar\x00");
    const tar = detect(&tar_buf);
    try std.testing.expectEqual(FormatId.tar, tar.id);
    try std.testing.expectEqualStrings("application/x-tar", tar.mime_type);

    // 3. Sliding-Window Signature Scanner (`findFirstEmbeddedSignature`) for R07 padding boxes
    var padding_window: [128]u8 = @splat(0x00);
    // Hide an ELF binary at offset 48 inside zero-padded `free` box
    @memcpy(padding_window[48..52], "\x7FELF");
    const hit = findFirstEmbeddedSignature(&padding_window, 4) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 48), hit.relative_offset);
    try std.testing.expectEqual(FormatId.elf, hit.info.id);
    try std.testing.expectEqualStrings("application/x-elf", hit.info.mime_type);
}
