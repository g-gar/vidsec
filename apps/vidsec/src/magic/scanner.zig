const std = @import("std");
const tika = @import("tika");
const executable = tika.executable;
const archive = tika.archive;
const document = tika.document;
const MagicInfo = tika.MagicInfo;

/// Represents a hostile signature discovered at `relative_offset` inside a byte window
/// (such as a `free`/`Void`/`JUNK` padding box, `mdat` slack space, or trailing overlay).
pub const SignatureHit = struct {
    relative_offset: usize,
    info: MagicInfo,
};

/// Result of scanning a tail buffer for appended polyglot archives (`ZIP EOCD`, `RAR`, `7z`).
pub const TailArchiveScan = struct {
    zip_eocd_offset: ?u64 = null,
    rar_offset: ?u64 = null,
    seven_z_offset: ?u64 = null,
};

/// Result of scanning a head buffer (`[0..head_len)`) for primary or secondary/embedded executables.
pub const HeadExecutableScan = struct {
    primary_at_zero: bool = false,
    secondary_offset: ?u64 = null,
};

/// Scans `buf` at `step`-byte intervals (clamped to `>= 1`) and returns the first embedded
/// hostile payload signature (`Executable`, `Archive`, `Document/DB`, or `Shebang Script`).
///
/// To prevent false positives on random high-entropy media bytes when `offset > 0`,
/// short 2-byte signatures like `"MZ"` or `"#!"` require secondary structural verification
/// (`PE\x00\x00` header or `#!` interpreter path prefix).
pub fn findFirstEmbeddedSignature(buf: []const u8, step: usize) ?SignatureHit {
    const stride = @max(step, 1);
    var offset: usize = 0;
    while (offset + 4 <= buf.len) : (offset += stride) {
        if (probeEmbeddedAt(buf[offset..])) |info| {
            return .{
                .relative_offset = offset,
                .info = info,
            };
        }
    }
    return null;
}

/// Checks whether `slice` starts with a high-confidence hostile signature suitable for sliding-window carving.
pub fn probeEmbeddedAt(slice: []const u8) ?MagicInfo {
    if (slice.len < 4) return null;

    const b0 = slice[0];
    switch (b0) {
        'M' => {
            // Require verified "PE\0\0" header or DOS stub signature when scanning arbitrary windows
            if (slice[1] == 'Z') {
                if (executable.detect(slice)) |info| {
                    if (info.id == .pe_exe) return info;
                    // Also accept DOS MZ if the relocation table offset at 0x18 is >= 0x40 (standard DOS/Win32 stub)
                    if (slice.len >= 0x40) {
                        const reloc_off = std.mem.readInt(u16, slice[0x18..0x1A], .little);
                        const lfanew = std.mem.readInt(u32, slice[0x3C..0x40], .little);
                        if (reloc_off == 0x0040 and lfanew >= 0x40 and lfanew <= 4096) {
                            return info;
                        }
                    }
                }
            }
        },
        0x7F, 0xFE, 0xCE, 0xCF, 0xCA, 0x00, 'd', 'B', 0xFF => {
            if (executable.detect(slice)) |info| {
                // For 0x00asm, require full 8-byte Wasm header (\0asm\x01\0\0\0) in sliding windows
                if (info.id == .wasm) {
                    if (slice.len >= 8 and std.mem.eql(u8, slice[0..8], "\x00asm\x01\x00\x00\x00")) {
                        return info;
                    }
                    return null;
                }
                return info;
            }
        },
        'P' => {
            // ZIP local header PK\x03\x04 with realistic version_needed (10..63) and compression_method (<= 99)
            if (slice.len >= 10 and std.mem.eql(u8, slice[0..4], "PK\x03\x04")) {
                const ver = std.mem.readInt(u16, slice[4..6], .little);
                const method = std.mem.readInt(u16, slice[8..10], .little);
                if (ver >= 10 and ver <= 63 and method <= 99) {
                    return archive.detect(slice);
                }
            }
        },
        'R', 0x37, 0xFD, 0x28, '!' => {
            if (archive.detect(slice)) |info| return info;
        },
        '%', 0xD0, 'S' => {
            if (document.detect(slice)) |info| return info;
        },
        '#' => {
            if (slice.len >= 7 and (std.mem.startsWith(u8, slice, "#!/bin/") or
                std.mem.startsWith(u8, slice, "#!/usr/") or
                std.mem.startsWith(u8, slice, "#! /bin") or
                std.mem.startsWith(u8, slice, "#! /usr") or
                std.mem.startsWith(u8, slice, "#EXTM3U")))
            {
                return document.detect(slice);
            }
        },
        else => {},
    }
    return null;
}

/// Scans the leading `head` buffer (first 16 bytes + first `max_scan_bytes`, typically `4096`)
/// for primary or secondary/inserted executable headers (`MZ` / `\x7FELF`).
pub fn scanHeadExecutables(head: []const u8, max_scan_bytes: usize) HeadExecutableScan {
    var out = HeadExecutableScan{};

    const first_16_len = @min(head.len, 16);
    var i: usize = 0;
    while (i + 2 <= first_16_len) : (i += 1) {
        if (head[i] == 'M' and head[i + 1] == 'Z') {
            if (i == 0) {
                out.primary_at_zero = true;
            } else if (out.secondary_offset == null) {
                out.secondary_offset = i;
            }
        }
        if (i + 4 <= first_16_len and std.mem.eql(u8, head[i .. i + 4], "\x7FELF")) {
            if (i == 0) {
                out.primary_at_zero = true;
            } else if (out.secondary_offset == null) {
                out.secondary_offset = i;
            }
        }
    }

    const scan_len = @min(head.len, max_scan_bytes);
    var off: usize = 1;
    while (off + 4 <= scan_len) : (off += 1) {
        if (std.mem.eql(u8, head[off .. off + 4], "\x7FELF")) {
            if (out.secondary_offset == null) out.secondary_offset = off;
            return out;
        }
        if (head[off] == 'M' and head[off + 1] == 'Z') {
            const rest = head[off..scan_len];
            if (isLikelyEmbeddedMzStub(rest)) {
                if (out.secondary_offset == null) out.secondary_offset = off;
                return out;
            }
        }
    }

    return out;
}

fn isLikelyEmbeddedMzStub(slice: []const u8) bool {
    if (slice.len < 4) return false;
    if ((slice[2] == 0x90 and slice[3] == 0x00) or (slice[2] == 0x50 and slice[3] == 0x00)) {
        return true;
    }
    if (probeEmbeddedAt(slice)) |info| {
        if (info.category == .executable) return true;
    }
    const stub_window = slice[0..@min(slice.len, 160)];
    if (std.mem.indexOf(u8, stub_window, "This program cannot be run in DOS mode") != null or
        std.mem.indexOf(u8, stub_window, "This program must be run under Win32") != null)
    {
        return true;
    }
    return false;
}

/// Searches a tail buffer (`tail`, starting at `tail_start_offset` in the file) for appended archive
/// markers (`PK\x05\x06` ZIP EOCD, `Rar!\x1A\x07`, and `7z\xBC\xAF\x27\x1C`).
pub fn scanTailArchives(tail: []const u8, tail_start_offset: u64) TailArchiveScan {
    var out = TailArchiveScan{};
    if (tail.len < 4) return out;

    const eocd_sig = "PK\x05\x06";
    const last_512_start: usize = if (tail.len > 512) tail.len - 512 else 0;
    if (std.mem.lastIndexOf(u8, tail[last_512_start..], eocd_sig)) |rel_in_512| {
        out.zip_eocd_offset = tail_start_offset + last_512_start + rel_in_512;
    } else if (std.mem.lastIndexOf(u8, tail, eocd_sig)) |rel_in_tail| {
        out.zip_eocd_offset = tail_start_offset + rel_in_tail;
    }

    const rar_sig = "Rar!\x1A\x07";
    if (std.mem.indexOf(u8, tail, rar_sig)) |rel_rar| {
        const abs_off = tail_start_offset + rel_rar;
        if (abs_off > 0) out.rar_offset = abs_off;
    }

    const seven_z_sig = &[_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C };
    if (std.mem.indexOf(u8, tail, seven_z_sig)) |rel_7z| {
        const abs_off = tail_start_offset + rel_7z;
        if (abs_off > 0) out.seven_z_offset = abs_off;
    }

    return out;
}

/// Fast, zero-allocation ASCII case-insensitive substring search (`needle_lower` must be lowercase ASCII).
pub fn containsAsciiIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return true;
    if (haystack.len < needle_lower.len) return false;
    const first_lower = needle_lower[0];
    const first_upper = std.ascii.toUpper(first_lower);
    const limit = haystack.len - needle_lower.len;

    var i: usize = 0;
    while (i <= limit) : (i += 1) {
        const ch = haystack[i];
        if (ch == first_lower or ch == first_upper) {
            var matched = true;
            for (needle_lower[1..], 1..) |n_ch, j| {
                if (std.ascii.toLower(haystack[i + j]) != n_ch) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
    }
    return false;
}

/// Fast ASCII case-insensitive equality check (`zero-allocation`).
pub fn eqlAsciiIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
