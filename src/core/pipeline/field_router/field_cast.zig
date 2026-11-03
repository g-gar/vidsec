const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite_core = @import("../../sqlite/mod.zig");
const Value = sqlite_core.Value;

/// Data type casting conversions.
pub const FieldCast = enum {
    none,
    int,
    float,
    boolean,
    text,

    pub fn parse(s: []const u8) FieldCast {
        if (std.mem.eql(u8, s, "int") or std.mem.eql(u8, s, "int64") or std.mem.eql(u8, s, "integer")) {
            return .int;
        }
        if (std.mem.eql(u8, s, "float") or std.mem.eql(u8, s, "float64") or std.mem.eql(u8, s, "real")) {
            return .float;
        }
        if (std.mem.eql(u8, s, "bool") or std.mem.eql(u8, s, "boolean")) {
            return .boolean;
        }
        if (std.mem.eql(u8, s, "text") or std.mem.eql(u8, s, "string")) {
            return .text;
        }
        return .none;
    }

    pub fn apply(self: FieldCast, allocator: Allocator, val: Value) !Value {
        return switch (self) {
            .none => val,
            .int => switch (val) {
                .int64 => val,
                .float64 => |f| Value{ .int64 = @intFromFloat(f) },
                .boolean => |b| Value{ .int64 = if (b) 1 else 0 },
                .text => |t| {
                    const parsed = std.fmt.parseInt(i64, t, 10) catch 0;
                    return Value{ .int64 = parsed };
                },
                else => val,
            },
            .float => switch (val) {
                .float64 => val,
                .int64 => |i| Value{ .float64 = @floatFromInt(i) },
                .boolean => |b| Value{ .float64 = if (b) 1.0 else 0.0 },
                .text => |t| {
                    const parsed = std.fmt.parseFloat(f64, t) catch 0.0;
                    return Value{ .float64 = parsed };
                },
                else => val,
            },
            .boolean => switch (val) {
                .boolean => val,
                .int64 => |i| Value{ .boolean = (i != 0) },
                .float64 => |f| Value{ .boolean = (f != 0.0) },
                .text => |t| Value{ .boolean = (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "1")) },
                else => val,
            },
            .text => switch (val) {
                .text => val,
                .int64 => |i| Value{ .text = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
                .float64 => |f| Value{ .text = try std.fmt.allocPrint(allocator, "{d}", .{f}) },
                .boolean => |b| Value{ .text = if (b) "true" else "false" },
                else => val,
            },
        };
    }
};
