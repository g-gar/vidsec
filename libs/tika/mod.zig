const std = @import("std");

pub const types = @import("types.zig");
pub const executable = @import("executable.zig");
pub const archive = @import("archive.zig");
pub const document = @import("document.zig");
pub const image_font = @import("image_font.zig");
pub const media = @import("media.zig");

pub const Category = types.Category;
pub const ContainerFamily = types.ContainerFamily;
pub const FormatId = types.FormatId;
pub const MagicInfo = types.MagicInfo;
pub const RECOMMENDED_HEADER_BYTES = types.RECOMMENDED_HEADER_BYTES;

/// Inspects the leading bytes of a file/stream (`buf`, anchored at offset `0x00`)
/// and returns its `MagicInfo` classification (`mime_type`, `extension`, `category`, `family`, `description`).
///
/// Runs in $O(1)$ bounded time and stack space with zero heap allocations.
pub fn detect(buf: []const u8) MagicInfo {
    if (buf.len < 2) return MagicInfo.UNKNOWN;

    // Tier 1: Native Executables & Bytecode at offset 0x00
    if (executable.detect(buf)) |info| return info;

    // Tier 2: Archives, Packages & Compressed Containers at offset 0x00
    if (archive.detect(buf)) |info| return info;

    // Tier 3: Documents, Databases, Scripts & Manifests at offset 0x00
    if (document.detect(buf)) |info| return info;

    // Tier 4: Standalone Raster Images & Fonts at offset 0x00
    if (image_font.detect(buf)) |info| return info;

    // Tier 5: Multimedia Containers (ISOBMFF, EBML, RIFF, MPEG-TS, OGG, FLV, ASF) & Audio Streams
    if (media.detect(buf)) |info| return info;

    return MagicInfo.UNKNOWN;
}

/// Returns `true` if and only if `buf` starts with a recognized video header.
pub inline fn isVideo(buf: []const u8) bool {
    return detect(buf).isVideo();
}

/// Returns `true` if `buf` starts with either a video or audio header.
pub inline fn isMultimedia(buf: []const u8) bool {
    return detect(buf).isMultimedia();
}

/// Detects the format of `buf` and checks whether it matches `ext_or_filename`.
pub inline fn matchesExtension(buf: []const u8, ext_or_filename: []const u8) bool {
    return detect(buf).matchesExtension(ext_or_filename);
}

test "tika detects video, image, archive, and executable signatures" {
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    const mp4_info = detect(mp4_hdr);
    try std.testing.expectEqual(FormatId.mp4, mp4_info.id);
    try std.testing.expectEqual(Category.video, mp4_info.category);
    try std.testing.expectEqual(ContainerFamily.isobmff, mp4_info.family);
    try std.testing.expectEqualStrings("video/mp4", mp4_info.mime_type);
    try std.testing.expect(mp4_info.isVideo());
    try std.testing.expect(mp4_info.isSupportedVideoContainer());
    try std.testing.expect(mp4_info.matchesExtension("sample.MP4"));
    try std.testing.expect(!mp4_info.matchesExtension("sample.mkv"));

    const png_hdr = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR";
    const png_info = detect(png_hdr);
    try std.testing.expectEqual(FormatId.png, png_info.id);
    try std.testing.expectEqual(Category.image, png_info.category);
    try std.testing.expect(!png_info.isVideo());
    try std.testing.expect(png_info.matchesExtension("cover.png"));

    const elf_hdr = "\x7FELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const elf_info = detect(elf_hdr);
    try std.testing.expectEqual(FormatId.elf, elf_info.id);
    try std.testing.expectEqual(Category.executable, elf_info.category);

    const zip_hdr = "PK\x03\x04\x14\x00\x00\x00\x08\x00\x00\x00\x00\x00";
    const zip_info = detect(zip_hdr);
    try std.testing.expectEqual(FormatId.zip, zip_info.id);
    try std.testing.expectEqual(Category.archive, zip_info.category);

    try std.testing.expectEqual(FormatId.unknown, detect(&.{0x00}).id);
}

