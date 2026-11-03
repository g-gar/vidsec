const std = @import("std");
const ValueTag_ABI = @import("value_tag_abi.zig").ValueTag_ABI;
const Slice_ABI = @import("slice_abi.zig").Slice_ABI;
const ValuePayload_ABI = @import("value_payload_abi.zig").ValuePayload_ABI;

/// Universal typed value passed across the C-ABI boundary for input row columns,
/// task parameters (`params:`), and emitted output fields (`emit_row`).
pub const Value_ABI = extern struct {
    tag: ValueTag_ABI,
    payload: ValuePayload_ABI,

    pub fn nullVal() Value_ABI {
        return .{
            .tag = .null_val,
            .payload = .{ .int64 = 0 },
        };
    }

    pub fn fromInt(v: i64) Value_ABI {
        return .{
            .tag = .int64,
            .payload = .{ .int64 = v },
        };
    }

    pub fn fromFloat(v: f64) Value_ABI {
        return .{
            .tag = .float64,
            .payload = .{ .float64 = v },
        };
    }

    pub fn fromBool(v: bool) Value_ABI {
        return .{
            .tag = .boolean,
            .payload = .{ .boolean = v },
        };
    }

    pub fn fromText(s: []const u8) Value_ABI {
        return .{
            .tag = .text,
            .payload = .{ .slice = Slice_ABI.fromSlice(s) },
        };
    }

    pub fn fromBlob(b: []const u8) Value_ABI {
        return .{
            .tag = .blob,
            .payload = .{ .slice = Slice_ABI.fromSlice(b) },
        };
    }

    pub fn isNull(self: Value_ABI) bool {
        return self.tag == .null_val;
    }

    pub fn asInt(self: Value_ABI) ?i64 {
        return if (self.tag == .int64) self.payload.int64 else null;
    }

    pub fn asFloat(self: Value_ABI) ?f64 {
        return switch (self.tag) {
            .float64 => self.payload.float64,
            .int64 => @floatFromInt(self.payload.int64),
            else => null,
        };
    }

    pub fn asBool(self: Value_ABI) ?bool {
        return switch (self.tag) {
            .boolean => self.payload.boolean,
            .int64 => self.payload.int64 != 0,
            else => null,
        };
    }

    pub fn asText(self: Value_ABI) ?[]const u8 {
        return if (self.tag == .text) self.payload.slice.toSlice() else null;
    }

    pub fn asBlob(self: Value_ABI) ?[]const u8 {
        return switch (self.tag) {
            .blob, .text => self.payload.slice.toSlice(),
            else => null,
        };
    }

    pub fn fromAny(val: anytype) Value_ABI {
        const T = @TypeOf(val);
        if (T == Value_ABI) return val;
        switch (@typeInfo(T)) {
            .null => return nullVal(),
            .optional => {
                if (val) |v| {
                    return fromAny(v);
                } else {
                    return nullVal();
                }
            },
            .bool => return fromBool(val),
            .int => return fromInt(@intCast(val)),
            .float => return fromFloat(@floatCast(val)),
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return fromText(val);
                }
                if (ptr_info.size == .one and @typeInfo(ptr_info.child) == .array and @typeInfo(ptr_info.child).array.child == u8) {
                    return fromText(val);
                }
                @compileError("Unsupported pointer type in fromAny: " ++ @typeName(T));
            },
            .@"enum" => {
                if (@hasDecl(T, "asText")) {
                    return fromText(val.asText());
                } else if (@hasDecl(T, "toInt")) {
                    return fromInt(val.toInt());
                } else {
                    return fromText(@tagName(val));
                }
            },
            else => @compileError("Unsupported type in fromAny: " ++ @typeName(T)),
        }
    }

    pub fn toAny(self: Value_ABI, comptime Target: type) ?Target {
        if (Target == Value_ABI) return self;
        if (self.isNull()) {
            if (@typeInfo(Target) == .optional) return null;
            return null;
        }
        const is_optional = @typeInfo(Target) == .optional;
        const ActualTarget = if (is_optional) @typeInfo(Target).optional.child else Target;
        switch (@typeInfo(ActualTarget)) {
            .bool => {
                if (self.asBool()) |b| return if (is_optional) @as(Target, b) else b;
                return null;
            },
            .int => {
                if (self.asInt()) |i| {
                    const casted = std.math.cast(ActualTarget, i) orelse return null;
                    return if (is_optional) @as(Target, casted) else casted;
                }
                return null;
            },
            .float => {
                if (self.asFloat()) |fl| {
                    const casted: ActualTarget = @floatCast(fl);
                    return if (is_optional) @as(Target, casted) else casted;
                }
                return null;
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    if (self.asText()) |txt| {
                        return if (is_optional) @as(Target, txt) else txt;
                    }
                }
                return null;
            },
            .@"enum" => {
                if (self.asText()) |txt| {
                    if (std.meta.stringToEnum(ActualTarget, txt)) |e| {
                        return if (is_optional) @as(Target, e) else e;
                    }
                }
                if (self.asInt()) |i| {
                    const tag_type = @typeInfo(ActualTarget).@"enum".tag_type;
                    if (std.math.cast(tag_type, i)) |casted_int| {
                        const enum_val: ActualTarget = @enumFromInt(casted_int);
                        return if (is_optional) @as(Target, enum_val) else enum_val;
                    }
                }
                return null;
            },
            else => return null,
        }
    }
};
