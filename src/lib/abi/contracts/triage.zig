const std = @import("std");

/// Normalized container family identifier emitted into `file_triage.detected_family`.
pub const DetectedFamily = enum {
    isobmff,
    ebml,
    riff,
    unknown,

    pub fn asText(self: DetectedFamily) []const u8 {
        return switch (self) {
            .isobmff => "isobmff",
            .ebml => "ebml",
            .riff => "riff",
            .unknown => "unknown",
        };
    }
};

/// Normalized magic signature classification emitted into `file_triage.true_magic_kind`
/// and `container_metadata.true_magic`.
/// Values `>= 10` represent non-video executables, archives, or scripts (`R01` spoofing detection).
pub const MagicKind = enum(i64) {
    unknown = 0,
    // Legitimate multimedia container families (1..9)
    isobmff = 1,
    ebml = 2,
    riff = 3,
    // Spoofed executables, archives, and scripts (>= 10 -> triggers R01)
    pe_mz = 10,
    elf = 11,
    mach_o = 12,
    zip_archive = 13,
    rar_archive = 14,
    gzip_archive = 15,
    seven_z = 16,
    pdf_doc = 17,
    shell_script = 18,
    wasm_bin = 19,
    java_class = 20,

    pub fn toInt(self: MagicKind) i64 {
        return @intFromEnum(self);
    }
};

/// Strongly-typed row for `triage.file_triage` (`configs/schemas.yaml`).
pub const FileTriageRow = struct {
    file_size: u64,
    detected_family: []const u8,
    true_magic_kind: i64,
    true_magic_name: []const u8,
    exceeds_size_limit: bool = false,
    verdict: []const u8 = "PASS",
    identified_format: []const u8 = "unknown",
    mime_type: []const u8 = "application/octet-stream",
    extension_match: bool = true,
    mid_entropy: f64 = 0.0,
    head_size_read: i64 = 0,
    tail_size_read: i64 = 0,
    flags_csv: []const u8 = "",
    suspicious_string: ?[]const u8 = null,
    zip_eocd_offset: ?i64 = null,
    report_json: ?[]const u8 = null,
};
