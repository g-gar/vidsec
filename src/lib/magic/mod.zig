const std = @import("std");

pub const types = @import("types.zig");
pub const executable = @import("executable.zig");
pub const archive = @import("archive.zig");
pub const document = @import("document.zig");
pub const image_font = @import("image_font.zig");
pub const media = @import("media.zig");
pub const scanner = @import("scanner.zig");

pub const Category = types.Category;
pub const ContainerFamily = types.ContainerFamily;
pub const ThreatClass = types.ThreatClass;
pub const FormatId = types.FormatId;
pub const MagicInfo = types.MagicInfo;
pub const RECOMMENDED_HEADER_BYTES = types.RECOMMENDED_HEADER_BYTES;
pub const SignatureHit = scanner.SignatureHit;
pub const TailArchiveScan = scanner.TailArchiveScan;
pub const HeadExecutableScan = scanner.HeadExecutableScan;

pub const findFirstEmbeddedSignature = scanner.findFirstEmbeddedSignature;
pub const probeEmbeddedAt = scanner.probeEmbeddedAt;
pub const scanHeadExecutables = scanner.scanHeadExecutables;
pub const scanTailArchives = scanner.scanTailArchives;
pub const containsAsciiIgnoreCase = scanner.containsAsciiIgnoreCase;
pub const eqlAsciiIgnoreCase = scanner.eqlAsciiIgnoreCase;

/// Inspects the leading bytes of a file/stream (`buf`, anchored strictly at physical offset `0x00`)
/// and returns its `MagicInfo` classification (`mime_type`, `extension`, `category`, `family`, `threat_class`).
///
/// ### Security Invariants (`R01_magic_mismatch`):
/// 1. **Hostile-First Evaluation Order:** Executables (`PE/MZ`, `ELF`, `Mach-O`, `Wasm`, `Java`, `DEX`),
///    archives (`ZIP`, `JAR`, `RAR`, `7z`, `TAR`), documents (`PDF`, `OLE2`), databases (`SQLite3`),
///    and scripts/manifests (`#!`, `#EXTM3U`, `<ASX`, `<html`, `<svg`) are evaluated at offset `0x00`
///    **before** inspecting offset `0x04` for ISOBMFF box tags (`ftyp`/`moov`/`free`).
/// 2. **Zero Tolerance for Displaced Headers:** Never scans forward past offset `0x00` to locate
///    container signatures, neutralizing prepend-style polyglots by design.
/// 3. **Zero Heap Allocations:** Runs in $O(1)$ bounded time and stack space.
pub fn detect(buf: []const u8) MagicInfo {
    if (buf.len < 2) return MagicInfo.UNKNOWN;

    // Tier 1: Native Executables & Bytecode at offset 0x00 (Highest priority for R01)
    if (executable.detect(buf)) |info| return info;

    // Tier 2: Archives, Packages & Compressed Containers at offset 0x00 (Polyglot vectors)
    if (archive.detect(buf)) |info| return info;

    // Tier 3: Documents, Databases, Shell Scripts & Network Manifests at offset 0x00
    if (document.detect(buf)) |info| return info;

    // Tier 4: Standalone Raster Images & Fonts at offset 0x00
    if (image_font.detect(buf)) |info| return info;

    // Tier 5: Multimedia Containers (ISOBMFF, EBML, RIFF, MPEG-TS, OGG, FLV, ASF) & Audio Streams
    if (media.detect(buf)) |info| return info;

    return MagicInfo.UNKNOWN;
}

/// Fast convenience predicate: returns `true` if and only if `buf` starts with a valid video header.
pub inline fn isVideo(buf: []const u8) bool {
    return detect(buf).isVideo();
}

/// Fast convenience predicate: returns `true` if `buf` starts with either a video or audio header.
pub inline fn isMultimedia(buf: []const u8) bool {
    return detect(buf).isMultimedia();
}


