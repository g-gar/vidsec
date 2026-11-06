const std = @import("std");

/// Fast check returning `true` if every byte in `buf` is `0x00` (`zero-allocation`).
/// Used to short-circuit legitimate `free`/`Void`/`JUNK` padding regions in nanoseconds.
pub fn isAllZero(buf: []const u8) bool {
    return isUniformByte(buf, 0x00);
}

/// Returns `true` if every byte in `buf` equals `target`.
pub fn isUniformByte(buf: []const u8, target: u8) bool {
    for (buf) |b| {
        if (b != target) return false;
    }
    return true;
}

/// Single-pass statistical summary of a byte buffer (`zero-allocation`).
pub const ByteStats = struct {
    total_bytes: u64,
    zero_count: u64,
    ascii_printable_count: u64,
    unique_byte_values: u16,
    entropy: f64,
    non_zero_entropy: f64,
    chi_square: f64,

    /// Fraction of `0x00` bytes in `[0.0, 1.0]`.
    pub fn zeroRatio(self: ByteStats) f64 {
        if (self.total_bytes == 0) return 0.0;
        return @as(f64, @floatFromInt(self.zero_count)) / @as(f64, @floatFromInt(self.total_bytes));
    }

    /// Fraction of printable ASCII bytes (`0x20..0x7E` plus `\t`, `\n`, `\r`) in `[0.0, 1.0]`.
    pub fn asciiPrintableRatio(self: ByteStats) f64 {
        if (self.total_bytes == 0) return 0.0;
        return @as(f64, @floatFromInt(self.ascii_printable_count)) / @as(f64, @floatFromInt(self.total_bytes));
    }

    /// Returns `true` if the buffer exhibits high overall Shannon entropy (`>= threshold`, typically `7.2`).
    pub fn isHighEntropy(self: ByteStats, threshold: f64) bool {
        return self.entropy >= threshold;
    }

    /// Detects the `R07` *Zero-Padded Entropy Evasion* pattern: a region padded mostly with `0x00`
    /// (`zeroRatio >= 0.50`) so its overall entropy stays low, while the non-zero bytes carry
    /// a dense binary/encrypted payload (`non_zero_entropy >= 5.5` and `>= 64` non-zero bytes).
    pub fn isZeroDilutedPayload(self: ByteStats) bool {
        const non_zero_count = self.total_bytes -| self.zero_count;
        return non_zero_count >= 64 and self.zeroRatio() >= 0.50 and self.non_zero_entropy >= 5.5;
    }
};

/// Computes `ByteStats` (`entropy`, `non_zero_entropy`, `chi_square`, `zero_count`, `ascii_printable_count`,
/// and `unique_byte_values`) in a single pass over `buf` with $O(1)$ stack memory.
pub fn computeByteStats(buf: []const u8) ByteStats {
    if (buf.len == 0) {
        return .{
            .total_bytes = 0,
            .zero_count = 0,
            .ascii_printable_count = 0,
            .unique_byte_values = 0,
            .entropy = 0.0,
            .non_zero_entropy = 0.0,
            .chi_square = 0.0,
        };
    }

    var counts: [256]u64 = @splat(0);
    for (buf) |b| {
        counts[b] += 1;
    }

    const total: u64 = buf.len;
    const total_f: f64 = @floatFromInt(total);
    const expected_uniform: f64 = total_f / 256.0;

    const zero_count = counts[0];
    const non_zero_total = total -| zero_count;
    const non_zero_f: f64 = @floatFromInt(non_zero_total);

    var ascii_count: u64 = counts['\t'] + counts['\n'] + counts['\r'];
    for (0x20..0x7F) |ascii_b| {
        ascii_count += counts[ascii_b];
    }

    var unique: u16 = 0;
    var h_all: f64 = 0.0;
    var h_nz: f64 = 0.0;
    var chi_sq: f64 = 0.0;

    for (counts, 0..) |c, byte_val| {
        const c_f: f64 = @floatFromInt(c);
        const diff = c_f - expected_uniform;
        chi_sq += (diff * diff) / expected_uniform;

        if (c > 0) {
            unique += 1;
            const p = c_f / total_f;
            h_all -= p * @log2(p);

            if (byte_val != 0 and non_zero_total > 0) {
                const p_nz = c_f / non_zero_f;
                h_nz -= p_nz * @log2(p_nz);
            }
        }
    }

    return .{
        .total_bytes = total,
        .zero_count = zero_count,
        .ascii_printable_count = ascii_count,
        .unique_byte_values = unique,
        .entropy = if (h_all < 0.0) 0.0 else h_all,
        .non_zero_entropy = if (h_nz < 0.0) 0.0 else h_nz,
        .chi_square = chi_sq,
    };
}
