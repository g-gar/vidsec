const std = @import("std");

const c = @cImport({
    @cInclude("sys/random.h");
    @cInclude("time.h");
});

/// Universally Unique Lexicographically Sortable Identifier (ULID) implementation.
/// Conforms to the standard ULID specification:
/// - 48-bit UNIX timestamp in milliseconds (characters 0..9)
/// - 80-bit entropy / randomness (characters 10..25)
/// - 26-character Crockford Base32 encoding (k-sortable, URL/file safe)
pub const Ulid = struct {
    pub const ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    pub const String = [26]u8;

    /// Generates a standard 26-character Crockford Base32 ULID.
    pub fn generate() String {
        return generateWithTimestamp(currentTimestampMs());
    }

    /// Generates a ULID with an explicit millisecond timestamp.
    pub fn generateWithTimestamp(ts_ms: u64) String {
        var str: String = undefined;
        encodeTimestamp(ts_ms, str[0..10]);

        var rand_bytes: [10]u8 = undefined;
        getRandomBytes(&rand_bytes);
        encodeRandomness(&rand_bytes, str[10..26]);

        return str;
    }

    /// Returns current time in milliseconds since Unix epoch.
    pub fn currentTimestampMs() u64 {
        var ts_spec: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &ts_spec);
        const sec: i64 = @intCast(ts_spec.tv_sec);
        const nsec: i64 = @intCast(ts_spec.tv_nsec);
        const total_ms = sec * 1000 + @divTrunc(nsec, 1_000_000);
        return if (total_ms > 0) @intCast(total_ms) else 0;
    }

    fn getRandomBytes(dest: []u8) void {
        if (c.getentropy(dest.ptr, dest.len) == 0) {
            return;
        }
        // Fallback to PRNG if getentropy fails
        const seed: u64 = currentTimestampMs();
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(dest);
    }

    fn encodeTimestamp(ts_ms: u64, dest: *[10]u8) void {
        const ts: u48 = @truncate(ts_ms);
        dest[0] = ENCODING[(ts >> 45) & 0x1F];
        dest[1] = ENCODING[(ts >> 40) & 0x1F];
        dest[2] = ENCODING[(ts >> 35) & 0x1F];
        dest[3] = ENCODING[(ts >> 30) & 0x1F];
        dest[4] = ENCODING[(ts >> 25) & 0x1F];
        dest[5] = ENCODING[(ts >> 20) & 0x1F];
        dest[6] = ENCODING[(ts >> 15) & 0x1F];
        dest[7] = ENCODING[(ts >> 10) & 0x1F];
        dest[8] = ENCODING[(ts >> 5) & 0x1F];
        dest[9] = ENCODING[ts & 0x1F];
    }

    fn encodeRandomness(r: *const [10]u8, dest: *[16]u8) void {
        dest[0] = ENCODING[(r[0] >> 3) & 0x1F];
        dest[1] = ENCODING[((r[0] & 0x07) << 2) | ((r[1] >> 6) & 0x03)];
        dest[2] = ENCODING[(r[1] >> 1) & 0x1F];
        dest[3] = ENCODING[((r[1] & 0x01) << 4) | ((r[2] >> 4) & 0x0F)];
        dest[4] = ENCODING[((r[2] & 0x0F) << 1) | ((r[3] >> 7) & 0x01)];
        dest[5] = ENCODING[(r[3] >> 2) & 0x1F];
        dest[6] = ENCODING[((r[3] & 0x03) << 3) | ((r[4] >> 5) & 0x07)];
        dest[7] = ENCODING[r[4] & 0x1F];

        dest[8] = ENCODING[(r[5] >> 3) & 0x1F];
        dest[9] = ENCODING[((r[5] & 0x07) << 2) | ((r[6] >> 6) & 0x03)];
        dest[10] = ENCODING[(r[6] >> 1) & 0x1F];
        dest[11] = ENCODING[((r[6] & 0x01) << 4) | ((r[7] >> 4) & 0x0F)];
        dest[12] = ENCODING[((r[7] & 0x0F) << 1) | ((r[8] >> 7) & 0x01)];
        dest[13] = ENCODING[(r[8] >> 2) & 0x1F];
        dest[14] = ENCODING[((r[8] & 0x03) << 3) | ((r[9] >> 5) & 0x07)];
        dest[15] = ENCODING[r[9] & 0x1F];
    }
};
