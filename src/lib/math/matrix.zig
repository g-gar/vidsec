const std = @import("std");

/// Converts a signed 32-bit `16.16` fixed-point integer (used in `ISOBMFF` `mvhd`/`tkhd` matrices) to `f64`.
pub inline fn fixed16_16ToFloat(raw: i32) f64 {
    return @as(f64, @floatFromInt(raw)) / 65536.0;
}

/// Converts a signed 32-bit `2.30` fixed-point integer (used in `ISOBMFF` `mvhd`/`tkhd` perspective column) to `f64`.
pub inline fn fixed2_30ToFloat(raw: i32) f64 {
    return @as(f64, @floatFromInt(raw)) / 1073741824.0;
}

/// $3 \times 3$ row-major floating-point matrix (`zero-allocation`).
/// Used for 2D affine video display transformations (`mvhd`/`tkhd` in MP4/MOV) and 3-channel color-space conversions.
pub const Mat3 = struct {
    m: [3][3]f64,

    pub const IDENTITY = Mat3{
        .m = .{
            .{ 1.0, 0.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 0.0, 1.0 },
        },
    };

    /// ITU-R BT.709 RGB -> YCbCr color conversion matrix.
    pub const BT709_RGB_TO_YCBCR = Mat3{
        .m = .{
            .{ 0.2126, 0.7152, 0.0722 },
            .{ -0.114572, -0.385428, 0.5 },
            .{ 0.5, -0.454153, -0.045847 },
        },
    };

    /// Parses the 36-byte (`9 x i32` Big-Endian) transformation matrix stored in `ISOBMFF` `mvhd` and `tkhd` boxes:
    /// `[a, b, u, c, d, v, x, y, w]` where `a, b, c, d, x, y` are `16.16` fixed-point and `u, v, w` are `2.30` fixed-point.
    pub fn fromIsobmffMatrixBytes(bytes: *const [36]u8) Mat3 {
        const a = fixed16_16ToFloat(std.mem.readInt(i32, bytes[0..4], .big));
        const b = fixed16_16ToFloat(std.mem.readInt(i32, bytes[4..8], .big));
        const u = fixed2_30ToFloat(std.mem.readInt(i32, bytes[8..12], .big));
        const c = fixed16_16ToFloat(std.mem.readInt(i32, bytes[12..16], .big));
        const d = fixed16_16ToFloat(std.mem.readInt(i32, bytes[16..20], .big));
        const v = fixed2_30ToFloat(std.mem.readInt(i32, bytes[20..24], .big));
        const x = fixed16_16ToFloat(std.mem.readInt(i32, bytes[24..28], .big));
        const y = fixed16_16ToFloat(std.mem.readInt(i32, bytes[28..32], .big));
        const w = fixed2_30ToFloat(std.mem.readInt(i32, bytes[32..36], .big));

        return .{
            .m = .{
                .{ a, b, u },
                .{ c, d, v },
                .{ x, y, w },
            },
        };
    }

    /// Computes the determinant $\det(M)$ of the $3 \times 3$ matrix.
    pub fn determinant(self: Mat3) f64 {
        const a = self.m[0][0];
        const b = self.m[0][1];
        const c = self.m[0][2];
        const d = self.m[1][0];
        const e = self.m[1][1];
        const f = self.m[1][2];
        const g = self.m[2][0];
        const h = self.m[2][1];
        const k = self.m[2][2];

        return a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g);
    }

    /// Computes the $2 \times 2$ upper-left linear scaling/rotation sub-determinant $(a \cdot d - b \cdot c)$.
    pub fn affineDeterminant2D(self: Mat3) f64 {
        return self.m[0][0] * self.m[1][1] - self.m[0][1] * self.m[1][0];
    }

    /// Matrix multiplication $A \times B$.
    pub fn mul(self: Mat3, other: Mat3) Mat3 {
        var res: Mat3 = undefined;
        for (0..3) |r| {
            for (0..3) |col| {
                var sum: f64 = 0.0;
                for (0..3) |k| {
                    sum += self.m[r][k] * other.m[k][col];
                }
                res.m[r][col] = sum;
            }
        }
        return res;
    }

    /// Multiplies a 3D column vector `v` by `self` ($M \cdot v$).
    pub fn mulVec3(self: Mat3, v: [3]f64) [3]f64 {
        return .{
            self.m[0][0] * v[0] + self.m[0][1] * v[1] + self.m[0][2] * v[2],
            self.m[1][0] * v[0] + self.m[1][1] * v[1] + self.m[1][2] * v[2],
            self.m[2][0] * v[0] + self.m[2][1] * v[1] + self.m[2][2] * v[2],
        };
    }

    /// Returns `true` if all matrix entries are finite and the 2D affine transformation is non-degenerate
    /// (prevents divide-by-zero / huge allocation exploits in video players caused by singular `tkhd` matrices).
    pub fn isNonDegenerateAffine(self: Mat3) bool {
        for (self.m) |row| {
            for (row) |val| {
                if (!std.math.isFinite(val)) return false;
            }
        }
        const det2d = @abs(self.affineDeterminant2D());
        return det2d >= 1e-6 and det2d <= 1e6 and @abs(self.m[2][2]) >= 1e-6;
    }
};
