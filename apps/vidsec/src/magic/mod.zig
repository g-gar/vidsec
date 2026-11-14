pub const tika = @import("tika");
pub const scanner = @import("scanner.zig");
pub const file_triage_row = @import("file_triage_row.zig");

pub const Category = tika.Category;
pub const ContainerFamily = tika.ContainerFamily;
pub const FormatId = tika.FormatId;
pub const MagicInfo = tika.MagicInfo;
pub const RECOMMENDED_HEADER_BYTES = tika.RECOMMENDED_HEADER_BYTES;

pub const detect = tika.detect;
pub const isVideo = tika.isVideo;
pub const isMultimedia = tika.isMultimedia;
pub const matchesExtension = tika.matchesExtension;

pub const SignatureHit = scanner.SignatureHit;
pub const TailArchiveScan = scanner.TailArchiveScan;
pub const HeadExecutableScan = scanner.HeadExecutableScan;

pub const DetectedFamily = file_triage_row.DetectedFamily;
pub const MagicKind = file_triage_row.MagicKind;
pub const FileTriageRow = file_triage_row.FileTriageRow;
pub const emitFileTriage = file_triage_row.emitFileTriage;

pub const findFirstEmbeddedSignature = scanner.findFirstEmbeddedSignature;
pub const probeEmbeddedAt = scanner.probeEmbeddedAt;
pub const scanHeadExecutables = scanner.scanHeadExecutables;
pub const scanTailArchives = scanner.scanTailArchives;
pub const containsAsciiIgnoreCase = scanner.containsAsciiIgnoreCase;
pub const eqlAsciiIgnoreCase = scanner.eqlAsciiIgnoreCase;

/// Security-oriented classification for VidSec triage, attachment auditing,
/// and padding/slack signature scanning.
pub const ThreatClass = enum(u8) {
    benign_media,
    benign_asset,
    archive_or_container,
    active_executable_or_script,
    unknown,
};

pub fn threatClassOf(info: MagicInfo) ThreatClass {
    return switch (info.category) {
        .video, .audio => .benign_media,
        .image => if (info.id == .svg) .active_executable_or_script else .benign_asset,
        .font => .benign_asset,
        .archive, .document, .database => .archive_or_container,
        .executable, .script, .manifest => .active_executable_or_script,
        .unknown => .unknown,
    };
}

pub inline fn isSafeAttachment(info: MagicInfo) bool {
    return threatClassOf(info) == .benign_asset;
}

pub inline fn isHostileInMedia(info: MagicInfo) bool {
    return switch (threatClassOf(info)) {
        .active_executable_or_script, .archive_or_container => true,
        else => false,
    };
}

/// Numeric classification tier compatible with SQLite `file_triage.true_magic_kind` queries.
pub fn kindCode(info: MagicInfo) i64 {
    return switch (info.category) {
        .unknown => 0,
        .video => 1,
        .audio => 2,
        .image => if (info.id == .svg) 21 else 3,
        .font => 4,
        .archive => 10,
        .document, .database => 11,
        .executable => 20,
        .script, .manifest => 21,
    };
}
