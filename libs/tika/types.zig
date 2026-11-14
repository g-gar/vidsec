const std = @import("std");

/// High-level functional classification of a detected binary format.
pub const Category = enum(u8) {
    video,
    audio,
    image,
    font,
    archive,
    document,
    database,
    executable,
    script,
    manifest,
    unknown,

    pub fn asText(self: Category) []const u8 {
        return @tagName(self);
    }
};

/// Multimedia container grammar family used to dispatch container parsers.
pub const ContainerFamily = enum(u8) {
    isobmff,
    ebml,
    riff,
    mpeg_ts,
    mpeg_ps,
    flv,
    ogg,
    asf,
    none,

    pub fn asText(self: ContainerFamily) []const u8 {
        return switch (self) {
            .none => "unknown",
            else => @tagName(self),
        };
    }
};

/// Canonical identifier for every supported binary and structured signature.
pub const FormatId = enum(u16) {
    // --- Video Containers & Streams ---
    mp4,
    mov,
    m4v,
    f4v,
    @"3gp",
    @"3g2",
    mkv,
    webm,
    avi,
    mpeg_ts,
    m2ts,
    mpeg_ps,
    mpeg_es,
    flv,
    ogv,
    asf_wmv,

    // --- Audio Containers & Streams ---
    m4a,
    mka,
    wav,
    ogg,
    oga,
    opus,
    flac,
    mp3,
    aac_adts,
    amr,
    aiff,
    midi,

    // --- Images ---
    png,
    jpeg,
    gif,
    webp,
    bmp,
    tiff_le,
    tiff_be,
    ico,
    cur,
    psd,
    heic,
    heif,
    avif,
    jp2,
    cr3,
    jxl,
    qoi,
    exr,
    ani,
    svg,

    // --- Fonts ---
    ttf,
    otf,
    woff,
    woff2,

    // --- Archives & Compressed Streams ---
    zip,
    jar_or_apk,
    epub,
    ooxml,
    odf,
    rar_v4,
    rar_v5,
    seven_z,
    gzip,
    bzip2,
    xz,
    zstd,
    lz4,
    tar,
    cab,
    ar_deb,
    rpm,

    // --- Documents & Databases ---
    pdf,
    ole2,
    rtf,
    sqlite3,
    pcap,
    pcapng,

    // --- Executables & Bytecode ---
    pe_exe,
    dos_mz,
    elf,
    macho_32,
    macho_64,
    macho_fat,
    wasm,
    java_class,
    dex,
    dey,
    llvm_bc,
    go_buildinfo,

    // --- Scripts & Network Manifests ---
    shebang_script,
    php_script,
    m3u8_playlist,
    asx_playlist,
    html_doc,
    xml_doc,

    // --- Fallback ---
    unknown,

    pub fn asText(self: FormatId) []const u8 {
        return @tagName(self);
    }
};

/// Recommended minimum header buffer size (`4096` bytes) to guarantee full detection
/// across all formats, including TAR (`offset 257`), MPEG-TS (3 x 192-byte packets = 576 bytes),
/// EBML `DocType` VINT scanning, and ZIP local header inspection.
pub const RECOMMENDED_HEADER_BYTES: usize = 4096;

/// Complete, zero-allocation descriptor returned by `tika.detect`.
pub const MagicInfo = struct {
    id: FormatId,
    category: Category,
    family: ContainerFamily,
    mime_type: []const u8,
    extension: []const u8,
    description: []const u8,

    pub const UNKNOWN = MagicInfo{
        .id = .unknown,
        .category = .unknown,
        .family = .none,
        .mime_type = "application/octet-stream",
        .extension = "bin",
        .description = "Unknown or unrecognized binary format",
    };

    /// Returns `true` if the detected format is a video container or elementary video stream.
    pub inline fn isVideo(self: MagicInfo) bool {
        return self.category == .video;
    }

    /// Returns `true` if the detected format is an audio container or audio stream.
    pub inline fn isAudio(self: MagicInfo) bool {
        return self.category == .audio;
    }

    /// Returns `true` if the detected format is either video or audio.
    pub inline fn isMultimedia(self: MagicInfo) bool {
        return self.category == .video or self.category == .audio;
    }

    /// Returns `true` if the format belongs to one of the structural container families
    /// (`isobmff`, `ebml`, `riff`, `mpeg_ts`) with an active video/audio payload.
    pub inline fn isSupportedVideoContainer(self: MagicInfo) bool {
        return self.category == .video and switch (self.family) {
            .isobmff, .ebml, .riff, .mpeg_ts => true,
            else => false,
        };
    }

    /// Returns `true` if any known signature matched.
    pub inline fn isKnown(self: MagicInfo) bool {
        return self.id != .unknown;
    }

    /// Returns `true` if `ext_or_filename` matches the canonical extension (or a well-known alias)
    /// for this detected format, case-insensitively.
    pub fn matchesExtension(self: MagicInfo, ext_or_filename: []const u8) bool {
        if (!self.isKnown()) return false;
        return matchesFormatExtension(self.id, self.extension, ext_or_filename);
    }
};

/// Returns `true` if `ext_or_filename` matches `canonical_ext` (or a well-known alias for `id`),
/// case-insensitively.
pub fn matchesFormatExtension(id: FormatId, canonical_ext: []const u8, ext_or_filename: []const u8) bool {
    if (id == .unknown or ext_or_filename.len == 0) return false;

    const base = std.fs.path.basename(ext_or_filename);
    const raw_ext = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot|
        base[dot + 1 ..]
    else
        base;

    if (raw_ext.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(raw_ext, canonical_ext)) return true;

    return switch (id) {
        .mov => std.ascii.eqlIgnoreCase(raw_ext, "qt"),
        .mpeg_ts => std.ascii.eqlIgnoreCase(raw_ext, "m2t") or std.ascii.eqlIgnoreCase(raw_ext, "mts"),
        .m2ts => std.ascii.eqlIgnoreCase(raw_ext, "mts") or std.ascii.eqlIgnoreCase(raw_ext, "ts"),
        .mpeg_ps, .mpeg_es => std.ascii.eqlIgnoreCase(raw_ext, "mpg") or std.ascii.eqlIgnoreCase(raw_ext, "mpeg"),
        .asf_wmv => std.ascii.eqlIgnoreCase(raw_ext, "asf") or std.ascii.eqlIgnoreCase(raw_ext, "wma"),
        .jpeg => std.ascii.eqlIgnoreCase(raw_ext, "jpg") or std.ascii.eqlIgnoreCase(raw_ext, "jpe"),
        .tiff_le, .tiff_be => std.ascii.eqlIgnoreCase(raw_ext, "tif"),
        .jar_or_apk => std.ascii.eqlIgnoreCase(raw_ext, "apk") or std.ascii.eqlIgnoreCase(raw_ext, "jar"),
        .html_doc => std.ascii.eqlIgnoreCase(raw_ext, "htm"),
        .midi => std.ascii.eqlIgnoreCase(raw_ext, "mid"),
        else => false,
    };
}

