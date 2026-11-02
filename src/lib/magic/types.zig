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

/// Multimedia container grammar family used by `vidsec` to dispatch format walkers.
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

/// Security-oriented classification for triage (`R01`), attachment auditing (`R06`),
/// and padding/slack signature scanning (`R02`, `R07`, `R08`).
pub const ThreatClass = enum(u8) {
    /// Recognized video or audio stream/container.
    benign_media,
    /// Passive static asset (e.g. raster image or font) — valid as an MKV/MP4 attachment (`R06`),
    /// but invalid as a root video container (`R01`).
    benign_asset,
    /// Archive, package, office document, or database capable of acting as a polyglot carrier.
    archive_or_container,
    /// Native executable, bytecode, shell script, or external network manifest (`M3U8`/`ASX`).
    active_executable_or_script,
    /// Unrecognized byte sequence.
    unknown,
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

/// Complete, zero-allocation descriptor returned by `magic.detect`.
pub const MagicInfo = struct {
    id: FormatId,
    category: Category,
    family: ContainerFamily,
    threat_class: ThreatClass,
    mime_type: []const u8,
    extension: []const u8,
    description: []const u8,

    pub const UNKNOWN = MagicInfo{
        .id = .unknown,
        .category = .unknown,
        .family = .none,
        .threat_class = .unknown,
        .mime_type = "application/octet-stream",
        .extension = "bin",
        .description = "Unknown or unrecognized binary format",
    };

    /// Returns `true` if the detected format is a video container or elementary video stream.
    /// In `vidsec` triage, this is the primary predicate: if `!info.isVideo()`, the file can be
    /// immediately rejected while using `info.mime_type` / `info.description` to log the exact cause.
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

    /// Returns `true` if the format is a benign static asset (`font` or raster `image`, excluding SVG scripts)
    /// suitable for embedded container attachments (`R06_embedded_attachments`).
    pub inline fn isSafeAttachment(self: MagicInfo) bool {
        return self.threat_class == .benign_asset;
    }

    /// Returns `true` if the format is an executable, script, network manifest, or archive/polyglot carrier.
    pub inline fn isHostileInMedia(self: MagicInfo) bool {
        return self.threat_class == .active_executable_or_script or
            self.threat_class == .archive_or_container;
    }

    /// Returns `true` if any known signature matched.
    pub inline fn isKnown(self: MagicInfo) bool {
        return self.id != .unknown;
    }

    /// Numeric classification tier compatible with SQLite `file_triage.true_magic_kind` queries:
    /// - `0`: Unknown format
    /// - `1`: Video
    /// - `2`: Audio
    /// - `3`: Image (raster)
    /// - `4`: Font
    /// - `10`: Archive / Compressed / Package (Polyglot vector)
    /// - `11`: Document / Database
    /// - `20`: Native Executable / Bytecode
    /// - `21`: Script / Network Manifest (`#!`, `M3U8`, `ASX`, `HTML`, `SVG`)
    ///
    /// Note: Any value `>= 10` indicates a non-media / hostile payload for `R01` SQL rules.
    pub fn kindCode(self: MagicInfo) i64 {
        return switch (self.category) {
            .unknown => 0,
            .video => 1,
            .audio => 2,
            .image => if (self.id == .svg) 21 else 3,
            .font => 4,
            .archive => 10,
            .document, .database => 11,
            .executable => 20,
            .script, .manifest => 21,
        };
    }
};
