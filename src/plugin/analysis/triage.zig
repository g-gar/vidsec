const std = @import("std");
const magic = @import("vidsec_magic");
const math = @import("vidsec_math");
const types = @import("types.zig");

pub const Verdict = types.Verdict;
pub const FixedBufWriter = types.FixedBufWriter;

pub const HEAD_BUFFER_MAX: usize = 64 * 1024; // 64 KB
pub const TAIL_BUFFER_MAX: usize = 64 * 1024; // 64 KB
pub const MID_BUFFER_MAX: usize = 4 * 1024; // 4 KB
pub const DEFAULT_MIN_FILE_SIZE: u64 = 128;
pub const MIN_VALID_VIDEO_SIZE: u64 = DEFAULT_MIN_FILE_SIZE;
pub const DEFAULT_MAX_FILE_SIZE_MB: u64 = 4096;
pub const DEFAULT_MIN_MID_ENTROPY: f64 = 5.5;
pub const AVI_MAX_SIZE_DELTA: u64 = 64 * 1024;

/// Canonical flag identifiers emitted by Stage 0 Triaging.
pub const TriageFlag = enum(u4) {
    file_too_small = 0,
    file_exceeds_max_size = 1,
    primary_magic_not_video = 2,
    primary_executable_detected = 3,
    extension_magic_mismatch = 4,
    ftyp_abnormal_box_size = 5,
    avi_riff_size_mismatch = 6,
    invalid_mpeg_ts_sync = 7,
    secondary_executable_in_head = 8,
    secondary_signature_zip_eocd_found = 9,
    secondary_signature_rar_found = 10,
    secondary_signature_7z_found = 11,
    suspicious_low_entropy = 12,
    suspicious_string_detected = 13,

    pub fn asText(self: TriageFlag) []const u8 {
        return switch (self) {
            .file_too_small => "FILE_TOO_SMALL",
            .file_exceeds_max_size => "FILE_EXCEEDS_MAX_SIZE",
            .primary_magic_not_video => "PRIMARY_MAGIC_NOT_VIDEO",
            .primary_executable_detected => "PRIMARY_EXECUTABLE_DETECTED",
            .extension_magic_mismatch => "EXTENSION_MAGIC_MISMATCH",
            .ftyp_abnormal_box_size => "FTYP_ABNORMAL_BOX_SIZE",
            .avi_riff_size_mismatch => "AVI_RIFF_SIZE_MISMATCH",
            .invalid_mpeg_ts_sync => "INVALID_MPEG_TS_SYNC",
            .secondary_executable_in_head => "SECONDARY_EXECUTABLE_IN_HEAD",
            .secondary_signature_zip_eocd_found => "SECONDARY_SIGNATURE_ZIP_EOCD_FOUND",
            .secondary_signature_rar_found => "SECONDARY_SIGNATURE_RAR_FOUND",
            .secondary_signature_7z_found => "SECONDARY_SIGNATURE_7Z_FOUND",
            .suspicious_low_entropy => "SUSPICIOUS_LOW_ENTROPY",
            .suspicious_string_detected => "SUSPICIOUS_STRING_DETECTED",
        };
    }
};

pub const ALL_FLAGS = [_]TriageFlag{
    .file_too_small,
    .file_exceeds_max_size,
    .primary_magic_not_video,
    .primary_executable_detected,
    .extension_magic_mismatch,
    .ftyp_abnormal_box_size,
    .avi_riff_size_mismatch,
    .invalid_mpeg_ts_sync,
    .secondary_executable_in_head,
    .secondary_signature_zip_eocd_found,
    .secondary_signature_rar_found,
    .secondary_signature_7z_found,
    .suspicious_low_entropy,
    .suspicious_string_detected,
};

/// Suspicious command execution stubs and dangerous URL schemes.
pub const SUSPICIOUS_PATTERNS = [_][]const u8{
    "#!/bin/",
    "/bin/sh",
    "powershell",
    "cmd.exe",
    "wscript.exe",
    "cscript.exe",
    "javascript:",
    "file://",
};

pub const TriageOptions = struct {
    file_path: []const u8 = "",
    expected_extension: []const u8 = "",
    min_file_size_bytes: u64 = DEFAULT_MIN_FILE_SIZE,
    max_file_size_bytes: u64 = DEFAULT_MAX_FILE_SIZE_MB * 1024 * 1024,
    min_mid_entropy: f64 = DEFAULT_MIN_MID_ENTROPY,
    strict_extension: bool = true,
};

/// Complete, zero-allocation Stage 0 Triage Report.
pub const TriageResult = struct {
    file_path: []const u8,
    file_size: u64,
    verdict: Verdict,
    magic_info: magic.MagicInfo,
    detected_family: []const u8,
    identified_format: []const u8,
    true_magic_kind: i64,
    true_magic_name: []const u8,
    extension_match: bool,
    exceeds_size_limit: bool,
    mid_entropy: f64,
    head_size_read: usize,
    tail_size_read: usize,
    mid_size_read: usize,

    flags_bitset: u16 = 0,
    secondary_exec_offset: ?u64 = null,
    zip_eocd_offset: ?u64 = null,
    tail_archive_offset: ?u64 = null,
    suspicious_strings_mask: u16 = 0,
    first_suspicious_string: []const u8 = "",

    pub fn hasFlag(self: TriageResult, flag: TriageFlag) bool {
        return (self.flags_bitset & (@as(u16, 1) << @intFromEnum(flag))) != 0;
    }

    pub fn addFlag(self: *TriageResult, flag: TriageFlag) void {
        self.flags_bitset |= (@as(u16, 1) << @intFromEnum(flag));
    }

    pub fn hasAnyFlags(self: TriageResult) bool {
        return self.flags_bitset != 0;
    }

    pub fn countFlags(self: TriageResult) usize {
        return @popCount(self.flags_bitset);
    }

    pub fn formatFlagsCsv(self: TriageResult, dest_buf: []u8) []const u8 {
        var fw = FixedBufWriter.init(dest_buf);
        var first = true;
        for (ALL_FLAGS) |flag| {
            if (self.hasFlag(flag)) {
                if (!first) fw.writeByte(',') catch {};
                fw.writeAll(flag.asText()) catch {};
                first = false;
            }
        }
        return fw.written();
    }

    pub fn formatJson(self: TriageResult, dest_buf: []u8) []const u8 {
        var fw = FixedBufWriter.init(dest_buf);
        fw.writeAll("{\"verdict\":\"") catch {};
        fw.writeAll(self.verdict.asText()) catch {};
        fw.writeAll("\",\"file_size\":") catch {};
        fw.print("{d}", .{self.file_size}) catch {};
        fw.writeAll(",\"format\":\"") catch {};
        fw.writeAll(self.identified_format) catch {};
        fw.writeAll("\",\"mid_entropy\":") catch {};
        fw.print("{d:.4}", .{self.mid_entropy}) catch {};
        fw.writeAll(",\"flags\":[") catch {};

        var first = true;
        for (ALL_FLAGS) |flag| {
            if (self.hasFlag(flag)) {
                if (!first) fw.writeByte(',') catch {};
                fw.writeByte('"') catch {};
                fw.writeAll(flag.asText()) catch {};
                fw.writeByte('"') catch {};
                first = false;
            }
        }
        fw.writeAll("]") catch {};

        if (self.first_suspicious_string.len > 0) {
            fw.writeAll(",\"suspicious_string\":") catch {};
            fw.writeByte('"') catch {};
            fw.writeJsonEscaped(self.first_suspicious_string) catch {};
            fw.writeByte('"') catch {};
        }

        if (self.zip_eocd_offset) |z_off| {
            fw.writeAll(",\"zip_eocd_offset\":") catch {};
            fw.print("{d}", .{z_off}) catch {};
        }

        fw.writeByte('}') catch {};
        return fw.written();
    }
};

/// Pure, zero-copy Stage 0 Triage analysis on an in-memory byte slice.
pub fn analyzeSlice(file_bytes: []const u8, opts: TriageOptions) TriageResult {
    const file_size = file_bytes.len;

    var result = TriageResult{
        .file_path = opts.file_path,
        .file_size = file_size,
        .verdict = .pass,
        .magic_info = magic.MagicInfo.UNKNOWN,
        .detected_family = "unknown",
        .identified_format = "unknown",
        .true_magic_kind = 0,
        .true_magic_name = "unknown",
        .extension_match = true,
        .exceeds_size_limit = false,
        .mid_entropy = 0.0,
        .head_size_read = 0,
        .tail_size_read = 0,
        .mid_size_read = 0,
    };

    // Check 1: File Size Bounds
    if (file_size < opts.min_file_size_bytes) {
        result.addFlag(.file_too_small);
    }
    if (file_size > opts.max_file_size_bytes) {
        result.exceeds_size_limit = true;
        result.addFlag(.file_exceeds_max_size);
    }

    // Read Head Buffer slice
    const head_len = @min(file_size, HEAD_BUFFER_MAX);
    const head_slice = file_bytes[0..head_len];
    result.head_size_read = head_len;

    // Check 2: Primary Magic Number, Container Header Sanity & Extension Match
    const m_info = magic.detect(head_slice);
    result.magic_info = m_info;
    result.detected_family = if (m_info.isVideo()) m_info.family.asText() else "unknown";
    result.identified_format = if (m_info.isKnown()) m_info.extension else "unknown";
    result.true_magic_kind = mapToAbiMagicKind(m_info);
    result.true_magic_name = if (m_info.isKnown()) m_info.id.asText() else "unknown";

    checkContainerHeaderSanity(head_slice, file_size, &result);

    if (!m_info.isVideo()) {
        result.addFlag(.primary_magic_not_video);
        if (m_info.category == .executable) {
            result.addFlag(.primary_executable_detected);
        }
    }

    const ext = resolveDeclaredExtension(opts);
    if (ext.len > 0) {
        if (!matchesDeclaredExtension(ext, m_info)) {
            result.extension_match = false;
            if (opts.strict_extension) {
                result.addFlag(.extension_magic_mismatch);
            }
            if (isTsExtension(ext) and m_info.family != .mpeg_ts) {
                result.addFlag(.invalid_mpeg_ts_sync);
            }
        }
    } else if (!m_info.isVideo()) {
        result.extension_match = false;
    }

    // Check 3 (Part A): Head Executables and Stubs
    const head_exec = magic.scanHeadExecutables(head_slice, 4096);
    if (head_exec.primary_at_zero) {
        result.addFlag(.primary_executable_detected);
    }
    if (head_exec.secondary_offset) |sec_off| {
        result.addFlag(.secondary_executable_in_head);
        result.secondary_exec_offset = sec_off;
    }

    // Check 5: Suspicious ASCII / Script Strings
    for (SUSPICIOUS_PATTERNS, 0..) |pat, idx| {
        if (magic.containsAsciiIgnoreCase(head_slice, pat)) {
            result.addFlag(.suspicious_string_detected);
            result.suspicious_strings_mask |= (@as(u16, 1) << @intCast(idx));
            if (result.first_suspicious_string.len == 0) {
                result.first_suspicious_string = pat;
            }
        }
    }

    // Check 4: Fast Sampled Shannon Entropy on Mid Buffer
    if (file_size > 0) {
        const mid_offset = file_size / 2;
        const avail_from_mid = file_size - mid_offset;
        const mid_len = @min(avail_from_mid, MID_BUFFER_MAX);
        const mid_slice = file_bytes[mid_offset .. mid_offset + mid_len];
        result.mid_size_read = mid_len;
        result.mid_entropy = math.shannonEntropy(mid_slice);

        if (file_size >= MIN_VALID_VIDEO_SIZE and result.mid_entropy < opts.min_mid_entropy) {
            result.addFlag(.suspicious_low_entropy);
        }
    }

    // Check 3 (Part B): Tail Appended Archives
    const tail_len = @min(file_size, TAIL_BUFFER_MAX);
    const tail_start_offset = file_size - tail_len;
    const tail_slice = file_bytes[tail_start_offset..file_size];
    result.tail_size_read = tail_len;

    const tail_scan = magic.scanTailArchives(tail_slice, tail_start_offset);
    if (tail_scan.zip_eocd_offset) |z_off| {
        result.addFlag(.secondary_signature_zip_eocd_found);
        result.zip_eocd_offset = z_off;
    }
    if (tail_scan.rar_offset) |r_off| {
        result.addFlag(.secondary_signature_rar_found);
        result.tail_archive_offset = r_off;
    }
    if (tail_scan.seven_z_offset) |s_off| {
        result.addFlag(.secondary_signature_7z_found);
        if (result.tail_archive_offset == null) result.tail_archive_offset = s_off;
    }

    // Compute Final Verdict
    result.verdict = computeVerdict(&result);
    return result;
}

fn checkContainerHeaderSanity(head: []const u8, file_size: u64, result: *TriageResult) void {
    if (head.len < 8) return;

    if (std.mem.eql(u8, head[4..8], "ftyp")) {
        const ftyp_size = std.mem.readInt(u32, head[0..4], .big);
        if (ftyp_size < 16 or ftyp_size > 4096 or (ftyp_size % 4) != 0) {
            result.addFlag(.ftyp_abnormal_box_size);
        }
    }

    if (head.len >= 12 and std.mem.eql(u8, head[0..4], "RIFF") and
        (std.mem.eql(u8, head[8..12], "AVI ") or std.mem.eql(u8, head[8..12], "AVIX")))
    {
        if (file_size >= 8) {
            const declared_riff_size: u64 = std.mem.readInt(u32, head[4..8], .little);
            const expected_riff_size: u64 = file_size - 8;
            const delta: u64 = if (expected_riff_size >= declared_riff_size)
                expected_riff_size - declared_riff_size
            else
                declared_riff_size - expected_riff_size;

            if (delta > AVI_MAX_SIZE_DELTA) {
                result.addFlag(.avi_riff_size_mismatch);
            }
        }
    }
}

fn computeVerdict(res: *const TriageResult) Verdict {
    if (res.hasFlag(.primary_executable_detected)) return .drop;
    if (res.hasFlag(.primary_magic_not_video) and res.hasFlag(.extension_magic_mismatch)) return .drop;
    if (res.hasFlag(.file_too_small)) return .drop;

    if (res.hasFlag(.secondary_signature_zip_eocd_found) or
        res.hasFlag(.secondary_signature_rar_found) or
        res.hasFlag(.secondary_signature_7z_found) or
        res.hasFlag(.secondary_executable_in_head) or
        res.hasFlag(.suspicious_string_detected) or
        res.hasFlag(.suspicious_low_entropy) or
        res.hasFlag(.extension_magic_mismatch) or
        res.hasFlag(.ftyp_abnormal_box_size) or
        res.hasFlag(.avi_riff_size_mismatch) or
        res.hasFlag(.invalid_mpeg_ts_sync) or
        res.hasFlag(.file_exceeds_max_size))
    {
        return .flagged;
    }

    return .pass;
}

fn resolveDeclaredExtension(opts: TriageOptions) []const u8 {
    if (opts.expected_extension.len > 0) {
        return if (opts.expected_extension[0] == '.') opts.expected_extension[1..] else opts.expected_extension;
    }
    if (opts.file_path.len > 0) {
        const ext = std.fs.path.extension(opts.file_path);
        if (ext.len > 1 and ext[0] == '.') {
            return ext[1..];
        }
    }
    return "";
}

fn isTsExtension(ext: []const u8) bool {
    return magic.eqlAsciiIgnoreCase(ext, "ts") or
        magic.eqlAsciiIgnoreCase(ext, "mts") or
        magic.eqlAsciiIgnoreCase(ext, "m2ts");
}

fn matchesDeclaredExtension(ext: []const u8, info: magic.MagicInfo) bool {
    if (!info.isVideo()) return false;
    if (magic.eqlAsciiIgnoreCase(ext, info.extension)) return true;

    if (info.family == .isobmff) {
        return magic.eqlAsciiIgnoreCase(ext, "mp4") or
            magic.eqlAsciiIgnoreCase(ext, "mov") or
            magic.eqlAsciiIgnoreCase(ext, "m4v") or
            magic.eqlAsciiIgnoreCase(ext, "3gp") or
            magic.eqlAsciiIgnoreCase(ext, "3g2") or
            magic.eqlAsciiIgnoreCase(ext, "f4v");
    }

    if (info.family == .ebml) {
        if (info.id == .mkv) return magic.eqlAsciiIgnoreCase(ext, "mkv") or magic.eqlAsciiIgnoreCase(ext, "mk3d");
        if (info.id == .webm) return magic.eqlAsciiIgnoreCase(ext, "webm");
    }

    if (info.family == .riff) {
        return magic.eqlAsciiIgnoreCase(ext, "avi");
    }

    if (info.family == .mpeg_ts) {
        return isTsExtension(ext);
    }

    if (info.family == .mpeg_ps) {
        return magic.eqlAsciiIgnoreCase(ext, "mpg") or
            magic.eqlAsciiIgnoreCase(ext, "mpeg") or
            magic.eqlAsciiIgnoreCase(ext, "vob");
    }

    return false;
}

pub fn mapToAbiMagicKind(info: magic.MagicInfo) i64 {
    if (info.isVideo()) {
        return switch (info.family) {
            .isobmff => magic.MagicKind.isobmff.toInt(),
            .ebml => magic.MagicKind.ebml.toInt(),
            .riff => magic.MagicKind.riff.toInt(),
            .mpeg_ts, .mpeg_ps, .flv, .ogg, .asf => 4,
            .none => 0,
        };
    }

    return switch (info.id) {
        .pe_exe, .dos_mz => magic.MagicKind.pe_mz.toInt(),
        .elf => magic.MagicKind.elf.toInt(),
        .macho_32, .macho_64, .macho_fat => magic.MagicKind.mach_o.toInt(),
        .zip, .jar_or_apk, .epub, .ooxml, .odf => magic.MagicKind.zip_archive.toInt(),
        .rar_v4, .rar_v5 => magic.MagicKind.rar_archive.toInt(),
        .gzip, .bzip2, .xz, .zstd, .lz4, .tar, .cab, .ar_deb, .rpm => magic.MagicKind.gzip_archive.toInt(),
        .seven_z => magic.MagicKind.seven_z.toInt(),
        .pdf, .ole2, .rtf, .sqlite3, .pcap, .pcapng, .xml_doc => magic.MagicKind.pdf_doc.toInt(),
        .shebang_script, .php_script, .m3u8_playlist, .asx_playlist, .html_doc, .svg => magic.MagicKind.shell_script.toInt(),
        .wasm, .dex, .dey, .llvm_bc, .go_buildinfo => magic.MagicKind.wasm_bin.toInt(),
        .java_class => magic.MagicKind.java_class.toInt(),
        .unknown => 0,
        else => 10,
    };
}

pub const ProbeFileOutput = struct {
    file_size: u64,
    detected_family: []const u8,
    true_magic_kind: i64,
    true_magic_name: []const u8,
    exceeds_size_limit: bool,
    verdict: []const u8,
    identified_format: []const u8,
    mime_type: []const u8,
    extension_match: bool,
    mid_entropy: f64,
    head_size_read: u64,
    tail_size_read: u64,
    flags_csv: []const u8,
    suspicious_string: []const u8 = "",
    zip_eocd_offset: i64 = -1,
};

/// Pure Black Box task for Level 0 triage (`analyzer/probe_file`).
pub fn probeFile(alloc: std.mem.Allocator, in: []const u8) !ProbeFileOutput {
    const res = analyzeSlice(in, .{});
    const flags_buf = try alloc.alloc(u8, 512);
    const flags_csv = res.formatFlagsCsv(flags_buf);

    return .{
        .file_size = res.file_size,
        .detected_family = res.detected_family,
        .true_magic_kind = res.true_magic_kind,
        .true_magic_name = res.true_magic_name,
        .exceeds_size_limit = res.exceeds_size_limit,
        .verdict = res.verdict.asText(),
        .identified_format = res.identified_format,
        .mime_type = res.magic_info.mime_type,
        .extension_match = res.extension_match,
        .mid_entropy = res.mid_entropy,
        .head_size_read = @intCast(res.head_size_read),
        .tail_size_read = @intCast(res.tail_size_read),
        .flags_csv = flags_csv,
        .suspicious_string = res.first_suspicious_string,
        .zip_eocd_offset = if (res.zip_eocd_offset) |o| @intCast(o) else -1,
    };
}
