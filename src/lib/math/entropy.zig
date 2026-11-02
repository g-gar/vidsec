const std = @import("std");

/// Streaming Shannon entropy accumulator over arbitrary byte chunks (`zero-allocation`).
/// Allows computing the exact Shannon entropy $H(X) \in [0.0, 8.0]$ of multi-gigabyte
/// streams or windows read in fixed-size chunks without holding the entire stream in memory.
pub const EntropyAccumulator = struct {
    counts: [256]u64 = @splat(0),
    total_bytes: u64 = 0,

    pub fn init() EntropyAccumulator {
        return .{};
    }

    pub fn reset(self: *EntropyAccumulator) void {
        self.counts = @splat(0);
        self.total_bytes = 0;
    }

    /// Incorporates a slice of bytes into the frequency histogram.
    pub fn update(self: *EntropyAccumulator, chunk: []const u8) void {
        for (chunk) |b| {
            self.counts[b] += 1;
        }
        self.total_bytes += chunk.len;
    }

    /// Computes the final Shannon entropy $H(X) = -\sum_{i=0}^{255} p_i \log_2(p_i)$ in bits per byte (`[0.0, 8.0]`).
    pub fn finish(self: *const EntropyAccumulator) f64 {
        if (self.total_bytes == 0) return 0.0;

        const total_f: f64 = @floatFromInt(self.total_bytes);
        var h: f64 = 0.0;

        for (self.counts) |c| {
            if (c > 0) {
                const p: f64 = @as(f64, @floatFromInt(c)) / total_f;
                h -= p * @log2(p);
            }
        }

        return if (h < 0.0) 0.0 else h;
    }

    /// Computes the Shannon entropy of only the non-zero bytes (`0x01..0xFF`), ignoring `0x00` filler.
    /// Useful for detecting Zero-Padded Entropy Evasion (`R07`), where an attacker dilutes a high-entropy
    /// payload inside a large zero-filled padding region.
    pub fn finishNonZero(self: *const EntropyAccumulator) f64 {
        const non_zero_total = self.total_bytes -| self.counts[0];
        if (non_zero_total == 0) return 0.0;

        const total_f: f64 = @floatFromInt(non_zero_total);
        var h: f64 = 0.0;

        for (self.counts[1..]) |c| {
            if (c > 0) {
                const p: f64 = @as(f64, @floatFromInt(c)) / total_f;
                h -= p * @log2(p);
            }
        }

        return if (h < 0.0) 0.0 else h;
    }
};

/// Computes the Shannon entropy $H(X) = -\sum_{i=0}^{255} p_i \log_2(p_i)$ in bits per byte (`[0.0, 8.0]`)
/// over `buf` in a single $O(N)$ pass using $O(1)$ stack space (`zero-allocation`).
pub fn shannonEntropy(buf: []const u8) f64 {
    if (buf.len == 0) return 0.0;

    // Fast path using 32-bit counters when buffer fits within u32 (< 4 GB)
    if (buf.len <= std.math.maxInt(u32)) {
        var counts: [256]u32 = @splat(0);
        for (buf) |b| {
            counts[b] += 1;
        }

        const total: f64 = @floatFromInt(buf.len);
        var entropy: f64 = 0.0;

        for (counts) |c| {
            if (c > 0) {
                const p: f64 = @as(f64, @floatFromInt(c)) / total;
                entropy -= p * @log2(p);
            }
        }

        return if (entropy < 0.0) 0.0 else entropy;
    }

    var acc = EntropyAccumulator.init();
    acc.update(buf);
    return acc.finish();
}

/// Computes the Shannon entropy of only the non-zero bytes (`b != 0x00`) in `buf`.
pub fn shannonEntropyNonZero(buf: []const u8) f64 {
    var acc = EntropyAccumulator.init();
    acc.update(buf);
    return acc.finishNonZero();
}
