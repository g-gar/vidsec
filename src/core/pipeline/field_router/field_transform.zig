const std = @import("std");
const sqlite_core = @import("../../sqlite/mod.zig");
const Value = sqlite_core.Value;

/// Arithmetic/math processing applied to numeric values.
pub const FieldTransform = enum {
    none,
    round,
    ceil,
    floor,
    abs,

    pub fn parse(s: []const u8) FieldTransform {
        if (std.mem.eql(u8, s, "round")) return .round;
        if (std.mem.eql(u8, s, "ceil")) return .ceil;
        if (std.mem.eql(u8, s, "floor")) return .floor;
        if (std.mem.eql(u8, s, "abs")) return .abs;
        return .none;
    }

    pub fn apply(self: FieldTransform, val: Value, round_decimals: ?u8) Value {
        return switch (self) {
            .none => {
                if (round_decimals) |dec| {
                    if (val == .float64) {
                        const factor = std.math.pow(f64, 10.0, @floatFromInt(dec));
                        return Value{ .float64 = @round(val.float64 * factor) / factor };
                    }
                }
                return val;
            },
            .round => switch (val) {
                .float64 => |f| {
                    if (round_decimals) |dec| {
                        const factor = std.math.pow(f64, 10.0, @floatFromInt(dec));
                        return Value{ .float64 = @round(f * factor) / factor };
                    }
                    return Value{ .float64 = @round(f) };
                },
                else => val,
            },
            .ceil => switch (val) {
                .float64 => |f| Value{ .float64 = @ceil(f) },
                else => val,
            },
            .floor => switch (val) {
                .float64 => |f| Value{ .float64 = @floor(f) },
                else => val,
            },
            .abs => switch (val) {
                .int64 => |i| Value{ .int64 = @intCast(@abs(i)) },
                .float64 => |f| Value{ .float64 = @abs(f) },
                else => val,
            },
        };
    }
};
