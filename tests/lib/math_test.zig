const std = @import("std");
const math = @import("vidsec_math");

const isAllZero = math.isAllZero;
const shannonEntropy = math.shannonEntropy;
const EntropyAccumulator = math.EntropyAccumulator;
const computeByteStats = math.computeByteStats;
const Interval = math.Interval;
const sortAndCheckOverlap = math.sortAndCheckOverlap;
const computeComplementGaps = math.computeComplementGaps;
const Mat3 = math.Mat3;

test "Shannon entropy (one-shot, streaming accumulator, and non-zero entropy for R07)" {
    // 1. Uniform 0x00 buffer -> entropy = 0.0
    var zeros: [512]u8 = @splat(0x00);
    try std.testing.expect(isAllZero(&zeros));
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), shannonEntropy(&zeros), 1e-9);

    // 2. Perfect 256-value uniform distribution -> entropy = 8.0 bits/byte
    var uniform_256: [1024]u8 = undefined;
    for (&uniform_256, 0..) |*b, idx| {
        b.* = @intCast(idx % 256);
    }
    try std.testing.expect(!isAllZero(&uniform_256));
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), shannonEntropy(&uniform_256), 1e-9);

    // 3. Streaming EntropyAccumulator matches one-shot shannonEntropy
    var acc = EntropyAccumulator.init();
    acc.update(uniform_256[0..300]);
    acc.update(uniform_256[300..700]);
    acc.update(uniform_256[700..1024]);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), acc.finish(), 1e-9);

    // 4. Zero-Padded Entropy Evasion (R07): 90% zeros + 10% high-entropy payload
    var diluted: [2048]u8 = @splat(0x00);
    var prng = std.Random.DefaultPrng.init(0x12345678);
    prng.fill(diluted[0..200]);

    const st = computeByteStats(&diluted);
    try std.testing.expect(st.entropy < 2.0); // Overall entropy is artificially low
    try std.testing.expect(st.non_zero_entropy >= 6.5); // Non-zero entropy exposes the hidden payload!
    try std.testing.expect(st.isZeroDilutedPayload());
}

test "Interval algebra: overlap detection (R10) and complement slack gaps (R08)" {
    var samples = [_]Interval{
        .{ .start = 150, .end = 190 },
        .{ .start = 100, .end = 130 },
    };
    try std.testing.expect(!sortAndCheckOverlap(&samples));

    const containers = [_]Interval{
        .{ .start = 100, .end = 200, .tag = "mdat" },
    };
    const gaps = try computeComplementGaps(std.testing.allocator, &containers, &samples);
    defer std.testing.allocator.free(gaps);

    try std.testing.expectEqual(@as(usize, 2), gaps.len);
    try std.testing.expectEqual(@as(u64, 130), gaps[0].start);
    try std.testing.expectEqual(@as(u64, 150), gaps[0].end);
    try std.testing.expectEqual(@as(u64, 190), gaps[1].start);
    try std.testing.expectEqual(@as(u64, 200), gaps[1].end);

    // Overlapping intervals (R10 decompression bomb)
    var overlapping = [_]Interval{
        .{ .start = 100, .end = 160 },
        .{ .start = 150, .end = 200 },
    };
    try std.testing.expect(sortAndCheckOverlap(&overlapping));
}

test "Matrix operations and ISOBMFF fixed-point transformation matrix validation" {
    const id = Mat3.IDENTITY;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), id.determinant(), 1e-9);
    try std.testing.expect(id.isNonDegenerateAffine());

    // Canonical 36-byte ISOBMFF identity matrix: a=0x00010000 (1.0), d=0x00010000 (1.0), w=0x40000000 (1.0 in 2.30)
    var iso_bytes: [36]u8 = @splat(0x00);
    std.mem.writeInt(i32, iso_bytes[0..4], 0x00010000, .big); // a = 1.0
    std.mem.writeInt(i32, iso_bytes[16..20], 0x00010000, .big); // d = 1.0
    std.mem.writeInt(i32, iso_bytes[32..36], 0x40000000, .big); // w = 1.0 (2.30)

    const parsed = Mat3.fromIsobmffMatrixBytes(&iso_bytes);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), parsed.determinant(), 1e-9);
    try std.testing.expect(parsed.isNonDegenerateAffine());
}
