const std = @import("std");
const types = @import("types.zig");
const ColumnType = types.ColumnType;
const DefaultValue = types.DefaultValue;
const ForeignKeyRef = types.ForeignKeyRef;
const ForeignKeyAction = types.ForeignKeyAction;

pub const ColumnSpec = struct {
    col_type: ColumnType,
    pk: bool = false,
    autoincrement: bool = false,
    nullable: bool = false,
    unique: bool = false,
    default_raw: ?[]const u8 = null,
    default_expr: ?[]const u8 = null,
    check: ?[]const u8 = null,
    collate: ?[]const u8 = null,
    generated_as: ?[]const u8 = null,
    stored: bool = false,
    ref: ?ForeignKeyRef = null,
    on_delete: ?ForeignKeyAction = null,
    on_update: ?ForeignKeyAction = null,

    pub fn parsedDefault(self: ColumnSpec) !?DefaultValue {
        if (self.default_expr) |expr| {
            if (expr.len == 0) return error.InvalidDefaultValue;
            return .{ .raw_expr = expr };
        }
        const raw = self.default_raw orelse return null;
        if (std.mem.eql(u8, raw, "null") and self.nullable) {
            return .null_val;
        }
        return switch (self.col_type) {
            .int64, .timestamp => .{ .int64 = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidDefaultValue },
            .uint64 => .{ .uint64 = std.fmt.parseInt(u64, raw, 10) catch return error.InvalidDefaultValue },
            .float64 => .{ .float64 = std.fmt.parseFloat(f64, raw) catch return error.InvalidDefaultValue },
            .bool => blk: {
                if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) break :blk .{ .boolean = true };
                if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0")) break :blk .{ .boolean = false };
                return error.InvalidDefaultValue;
            },
            .text, .json, .enum_type, .any => .{ .text = raw },
            .bytes, .blob => error.InvalidDefaultValue,
        };
    }

    pub fn validate(self: *const ColumnSpec) !void {
        if (self.default_raw != null and self.default_expr != null) {
            return error.InvalidDefaultValue;
        }
        _ = try self.parsedDefault();
    }
};
