const std = @import("std");
const types = @import("types.zig");
const MagicInfo = types.MagicInfo;

/// Detects native executables, object files, and virtual machine bytecode anchored at offset `0x00`.
/// Evaluated BEFORE multimedia headers to enforce `R01` Hostile-First security invariants.
pub fn detect(buf: []const u8) ?MagicInfo {
    if (buf.len < 2) return null;

    // 1. Windows PE / DOS MZ Executable ("MZ" at 0x00..0x02)
    // Note: Evaluated unconditionally at 0x00 so a polyglot with "MZ" + "free" at 0x04 is caught as PE/MZ.
    if (buf[0] == 'M' and buf[1] == 'Z') {
        if (hasPeHeader(buf)) {
            return .{
                .id = .pe_exe,
                .category = .executable,
                .family = .none,
                .mime_type = "application/vnd.microsoft.portable-executable",
                .extension = "exe",
                .description = "Windows Portable Executable (PE/COFF)",
            };
        }
        return .{
            .id = .dos_mz,
            .category = .executable,
            .family = .none,
            .mime_type = "application/x-dosexec",
            .extension = "exe",
            .description = "MS-DOS / Windows MZ Executable",
        };
    }

    if (buf.len < 4) return null;

    // 2. Linux / Unix ELF ("\x7FELF" at 0x00..0x04)
    if (std.mem.eql(u8, buf[0..4], "\x7FELF")) {
        return .{
            .id = .elf,
            .category = .executable,
            .family = .none,
            .mime_type = "application/x-elf",
            .extension = "elf",
            .description = "ELF Executable and Linkable Format",
        };
    }

    // 3. Apple Mach-O (32-bit, 64-bit, both endiannesses) and CAFEBABE (Mach-O Fat vs Java Class)
    const magic_be = std.mem.readInt(u32, buf[0..4], .big);
    switch (magic_be) {
        0xFEEDFACE, 0xCEFAEDFE => return .{
            .id = .macho_32,
            .category = .executable,
            .family = .none,
            .mime_type = "application/x-mach-binary",
            .extension = "macho",
            .description = "macOS Mach-O 32-bit Binary",
        },
        0xFEEDFACF, 0xCFFAEDFE => return .{
            .id = .macho_64,
            .category = .executable,
            .family = .none,
            .mime_type = "application/x-mach-binary",
            .extension = "macho",
            .description = "macOS Mach-O 64-bit Binary",
        },
        0xCAFEBABE, 0xCAFEBFBE => {
            // Disambiguate Apple Universal Binary (Fat Mach-O) vs Java Bytecode (.class):
            // In Fat Mach-O, bytes 4..8 (u32 BE) is `nfat_arch` (number of architectures, typically 1..30).
            // In Java .class, bytes 4..6 is `minor_version` and bytes 6..8 (u16 BE) is `major_version` (>= 45 for JDK 1.1+).
            if (magic_be == 0xCAFEBABE and buf.len >= 8) {
                const nfat_arch = std.mem.readInt(u32, buf[4..8], .big);
                const java_major = std.mem.readInt(u16, buf[6..8], .big);
                if (nfat_arch == 0 or (nfat_arch > 30 and java_major >= 45)) {
                    return .{
                        .id = .java_class,
                        .category = .executable,
                        .family = .none,
                        .mime_type = "application/java-vm",
                        .extension = "class",
                        .description = "Java Bytecode Class File",
                    };
                }
            }
            return .{
                .id = .macho_fat,
                .category = .executable,
                .family = .none,
                .mime_type = "application/x-mach-binary",
                .extension = "macho",
                .description = "macOS Universal Mach-O (Fat) Binary",
            };
        },
        else => {},
    }

    // 4. WebAssembly Binary ("\x00asm" + version 01 00 00 00)
    if (std.mem.eql(u8, buf[0..4], "\x00asm")) {
        return .{
            .id = .wasm,
            .category = .executable,
            .family = .none,
            .mime_type = "application/wasm",
            .extension = "wasm",
            .description = "WebAssembly Binary Module (Wasm)",
        };
    }

    // 5. Android Dalvik Executable (DEX "dex\n035\x00" / Optimized DEY "dey\n036\x00")
    if (buf.len >= 8 and std.mem.eql(u8, buf[0..4], "dex\n") and buf[7] == 0x00) {
        return .{
            .id = .dex,
            .category = .executable,
            .family = .none,
            .mime_type = "application/vnd.android.dex",
            .extension = "dex",
            .description = "Android Dalvik Executable (DEX)",
        };
    }
    if (buf.len >= 8 and std.mem.eql(u8, buf[0..4], "dey\n") and buf[7] == 0x00) {
        return .{
            .id = .dey,
            .category = .executable,
            .family = .none,
            .mime_type = "application/vnd.android.dey",
            .extension = "dey",
            .description = "Android Optimized Dalvik Executable (ODEX/DEY)",
        };
    }

    // 6. LLVM Bitcode ("BC\xC0\xDE")
    if (std.mem.eql(u8, buf[0..4], "BC\xC0\xDE")) {
        return .{
            .id = .llvm_bc,
            .category = .executable,
            .family = .none,
            .mime_type = "application/x-llvm-bc",
            .extension = "bc",
            .description = "LLVM IR Bitcode",
        };
    }

    // 7. Go Runtime BuildInfo Magic ("\xff Go buildinf:")
    if (buf.len >= 14 and std.mem.eql(u8, buf[0..14], "\xff Go buildinf:")) {
        return .{
            .id = .go_buildinfo,
            .category = .executable,
            .family = .none,
            .mime_type = "application/x-go-buildinfo",
            .extension = "go",
            .description = "Go Compiler BuildInfo Header",
        };
    }

    return null;
}

fn hasPeHeader(buf: []const u8) bool {
    if (buf.len < 0x40) return false;
    const e_lfanew = std.mem.readInt(u32, buf[0x3C..0x40], .little);
    const pe_offset: usize = @intCast(e_lfanew);
    const end = std.math.add(usize, pe_offset, 4) catch return false;
    if (end > buf.len) return false;
    return std.mem.eql(u8, buf[pe_offset..end], "PE\x00\x00");
}
