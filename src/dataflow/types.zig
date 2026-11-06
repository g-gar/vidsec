const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("../abi/mod.zig");

/// Lightweight ephemeral view of a field value extracted via compile-time reflection.
/// Allows zero-copy inspection of native Zig structs for filtering and serialization.
pub const ReflectedValue = union(enum) {
    none: void,
    int: i64,
    uint: u64,
    float: f64,
    boolean: bool,
    string: []const u8,
    bytes: []const u8,
    unsupported: void,

    pub fn fromInt(v: anytype) ReflectedValue {
        const info = @typeInfo(@TypeOf(v));
        if (info == .int and info.int.signedness == .unsigned) {
            return .{ .uint = @intCast(v) };
        }
        return .{ .int = @intCast(v) };
    }

    pub fn fromFloat(v: anytype) ReflectedValue {
        return .{ .float = @floatCast(v) };
    }

    pub fn fromBool(v: bool) ReflectedValue {
        return .{ .boolean = v };
    }

    pub fn fromString(v: []const u8) ReflectedValue {
        return .{ .string = v };
    }

    pub fn asFloat(self: ReflectedValue) ?f64 {
        return switch (self) {
            .float => |v| v,
            .int => |v| @floatFromInt(v),
            .uint => |v| @floatFromInt(v),
            else => null,
        };
    }

    pub fn asInt(self: ReflectedValue) ?i64 {
        return switch (self) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => null,
        };
    }

    pub fn asString(self: ReflectedValue) ?[]const u8 {
        return switch (self) {
            .string => |v| v,
            .bytes => |v| v,
            else => null,
        };
    }

    pub fn asBool(self: ReflectedValue) ?bool {
        return switch (self) {
            .boolean => |v| v,
            .int => |v| v != 0,
            .uint => |v| v != 0,
            else => null,
        };
    }

    pub fn isTruthy(self: ReflectedValue) bool {
        return switch (self) {
            .none => false,
            .int => |v| v != 0,
            .uint => |v| v != 0,
            .float => |v| v != 0.0,
            .boolean => |v| v,
            .string => |v| v.len > 0,
            .bytes => |v| v.len > 0,
            .unsupported => false,
        };
    }

    pub fn equals(self: ReflectedValue, other: ReflectedValue) bool {
        return switch (self) {
            .none => other == .none,
            .int => |v| switch (other) {
                .int => |ov| v == ov,
                .uint => |ov| v >= 0 and @as(u64, @intCast(v)) == ov,
                .float => |ov| @as(f64, @floatFromInt(v)) == ov,
                else => false,
            },
            .uint => |v| switch (other) {
                .uint => |ov| v == ov,
                .int => |ov| ov >= 0 and v == @as(u64, @intCast(ov)),
                .float => |ov| @as(f64, @floatFromInt(v)) == ov,
                else => false,
            },
            .float => |v| switch (other) {
                .float => |ov| v == ov,
                .int => |ov| v == @as(f64, @floatFromInt(ov)),
                .uint => |ov| v == @as(f64, @floatFromInt(ov)),
                else => false,
            },
            .boolean => |v| switch (other) {
                .boolean => |ov| v == ov,
                else => false,
            },
            .string => |v| switch (other) {
                .string => |ov| std.mem.eql(u8, v, ov),
                .bytes => |ov| std.mem.eql(u8, v, ov),
                else => false,
            },
            .bytes => |v| switch (other) {
                .string => |ov| std.mem.eql(u8, v, ov),
                .bytes => |ov| std.mem.eql(u8, v, ov),
                else => false,
            },
            .unsupported => false,
        };
    }
};

/// Reflectively extracts a named field from any native Zig struct at zero runtime allocation cost.
pub fn reflectField(comptime T: type, item_ptr: *const T, field_name: []const u8) ?ReflectedValue {
    if (T == DynamicRecord) {
        return item_ptr.getReflected(field_name);
    }

    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                if (std.mem.eql(u8, f.name, field_name)) {
                    const field_val = @field(item_ptr, f.name);
                    return reflectAny(f.type, field_val);
                }
            }
            return null;
        },
        else => return null,
    }
}

/// Helper to convert a typed field value into a ReflectedValue.
pub fn reflectAny(comptime F: type, val: F) ReflectedValue {
    const finfo = @typeInfo(F);
    switch (finfo) {
        .int => {
            if (finfo.int.signedness == .signed) {
                return .{ .int = @intCast(val) };
            } else {
                return .{ .uint = @intCast(val) };
            }
        },
        .float => return .{ .float = @floatCast(val) },
        .bool => return .{ .boolean = val },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                return .{ .string = val };
            }
            return .unsupported;
        },
        .array => |a| {
            if (a.child == u8) {
                return .{ .string = &val };
            }
            return .unsupported;
        },
        .optional => {
            if (val) |v| {
                return reflectAny(finfo.optional.child, v);
            } else {
                return .none;
            }
        },
        .null => return .none,
        else => return .unsupported,
    }
}

/// Zero-copy type-erased fat pointer for transporting native Zig structs or streams
/// across pipeline task boundaries without allocating dynamic wrappers.
pub const PayloadHandle = struct {
    ptr: *const anyopaque,
    len: usize, // 1 if scalar, N if slice/stream
    is_stream: bool,
    type_name: []const u8,
    element_size: usize,
    element_align: u29,
    reflect_fn: ?*const fn (ptr: *const anyopaque, field_name: []const u8) ?ReflectedValue = null,
    reflect_abi_fn: ?abi.ReflectFn_ABI = null,

    pub fn fromScalar(comptime T: type, item: *const T) PayloadHandle {
        const Trampoline = struct {
            fn reflect(ptr: *const anyopaque, field: []const u8) ?ReflectedValue {
                const typed: *const T = @ptrCast(@alignCast(ptr));
                return reflectField(T, typed, field);
            }
        };

        return .{
            .ptr = @ptrCast(item),
            .len = 1,
            .is_stream = false,
            .type_name = @typeName(T),
            .element_size = @sizeOf(T),
            .element_align = @alignOf(T),
            .reflect_fn = &Trampoline.reflect,
        };
    }

    pub fn fromSlice(comptime T: type, items: []const T) PayloadHandle {
        const Trampoline = struct {
            fn reflect(ptr: *const anyopaque, field: []const u8) ?ReflectedValue {
                const typed: [*]const T = @ptrCast(@alignCast(ptr));
                return reflectField(T, &typed[0], field);
            }
        };

        return .{
            .ptr = @ptrCast(items.ptr),
            .len = items.len,
            .is_stream = true,
            .type_name = @typeName(T),
            .element_size = @sizeOf(T),
            .element_align = @alignOf(T),
            .reflect_fn = if (items.len > 0) &Trampoline.reflect else null,
        };
    }

    pub fn getReflected(self: PayloadHandle, field_name: []const u8) ?ReflectedValue {
        if (self.reflect_fn) |rf| {
            return rf(self.ptr, field_name);
        }
        if (self.reflect_abi_fn) |rf_abi| {
            const res = rf_abi(self.ptr, field_name.ptr, field_name.len);
            return switch (res.tag) {
                .none => null,
                .int => .{ .int = res.int_val },
                .uint => .{ .uint = @intCast(res.int_val) },
                .float => .{ .float = res.float_val },
                .boolean => .{ .boolean = res.int_val != 0 },
                .string => if (res.str_ptr) |sptr| .{ .string = sptr[0..res.str_len] } else null,
            };
        }
        return null;
    }

    pub fn asSlice(self: PayloadHandle, comptime T: type) []const T {
        if (self.len == 0) return &.{};
        const typed_ptr: [*]const T = @ptrCast(@alignCast(self.ptr));
        return typed_ptr[0..self.len];
    }

    pub fn asScalar(self: PayloadHandle, comptime T: type) *const T {
        return @ptrCast(@alignCast(self.ptr));
    }
};

// =============================================================================
// OPTIONAL DYNAMIC FALLBACK (Used only for ad-hoc / schema-less queries)
// =============================================================================

pub const DynamicField = struct {
    name: []const u8,
    value: ReflectedValue,

    pub fn init(name: []const u8, value: ReflectedValue) DynamicField {
        return .{ .name = name, .value = value };
    }
};

pub const DynamicRecord = struct {
    fields: []const DynamicField,

    pub fn init(fields: []const DynamicField) DynamicRecord {
        return .{ .fields = fields };
    }

    pub fn getReflected(self: *const DynamicRecord, name: []const u8) ?ReflectedValue {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) {
                return f.value;
            }
        }
        return null;
    }
};
