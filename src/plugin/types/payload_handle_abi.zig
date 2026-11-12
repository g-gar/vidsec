const std = @import("std");

pub const ReflectedTag_ABI = enum(u32) {
    none = 0,
    int = 1,
    uint = 2,
    float = 3,
    boolean = 4,
    string = 5,
};

pub const ReflectedValue_ABI = extern struct {
    tag: ReflectedTag_ABI = .none,
    int_val: i64 = 0,
    float_val: f64 = 0.0,
    str_ptr: ?[*]const u8 = null,
    str_len: usize = 0,

    pub fn asBool(self: ReflectedValue_ABI) ?bool {
        return switch (self.tag) {
            .boolean => self.int_val != 0,
            .int, .uint => self.int_val != 0,
            else => null,
        };
    }

    pub fn asInt(self: ReflectedValue_ABI) ?i64 {
        return switch (self.tag) {
            .int, .uint => self.int_val,
            else => null,
        };
    }

    pub fn asFloat(self: ReflectedValue_ABI) ?f64 {
        return switch (self.tag) {
            .float => self.float_val,
            .int, .uint => @floatFromInt(self.int_val),
            else => null,
        };
    }

    pub fn asString(self: ReflectedValue_ABI) ?[]const u8 {
        if (self.tag == .string) {
            if (self.str_ptr) |p| return p[0..self.str_len];
        }
        return null;
    }

    pub fn isTruthy(self: ReflectedValue_ABI) bool {
        return switch (self.tag) {
            .none => false,
            .boolean => self.int_val != 0,
            .int, .uint => self.int_val != 0,
            .float => self.float_val != 0.0,
            .string => self.str_len > 0,
        };
    }
};

pub const ReflectFn_ABI = *const fn (
    ptr: *const anyopaque,
    field_ptr: [*]const u8,
    field_len: usize,
) callconv(.c) ReflectedValue_ABI;

pub const PayloadRepr_ABI = enum(u8) {
    bytes = 0,
    typed = 1,
    dynamic = 2,
};

/// C-ABI compliant zero-copy fat handle for passing typed items, slices, or raw byte streams
/// between host dataflow engine and dynamic plugin tasks.
pub const PayloadHandle_ABI = extern struct {
    ptr: ?*const anyopaque = null,
    len: usize = 0,
    element_size: usize = 0,
    element_align: u32 = 1,
    is_stream: bool = false,
    reflect_fn: ?ReflectFn_ABI = null,
    // ARCH-016 additions
    repr: PayloadRepr_ABI = .bytes,
    schema_id: u64 = 0,
    type_name_ptr: ?[*]const u8 = null,
    type_name_len: usize = 0,

    pub fn typeName(self: PayloadHandle_ABI) []const u8 {
        if (self.type_name_ptr) |p| {
            return p[0..self.type_name_len];
        }
        return "";
    }

    pub fn getReflected(self: PayloadHandle_ABI, field_name: []const u8) ?ReflectedValue_ABI {
        if (self.reflect_fn) |rf| {
            if (self.ptr) |p| {
                const val = rf(p, field_name.ptr, field_name.len);
                if (val.tag != .none) return val;
            }
        }
        return null;
    }

    pub fn empty() PayloadHandle_ABI {
        return .{};
    }

    pub fn fromScalar(comptime T: type, item: *const T) PayloadHandle_ABI {
        const Trampoline = struct {
            fn reflect(ptr: *const anyopaque, field_ptr: [*]const u8, field_len: usize) callconv(.c) ReflectedValue_ABI {
                const typed: *const T = @ptrCast(@alignCast(ptr));
                const field = field_ptr[0..field_len];
                const info = @typeInfo(T);
                if (info == .@"struct") {
                    inline for (info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, field)) {
                            const val = @field(typed, f.name);
                            const finfo = @typeInfo(f.type);
                            if (finfo == .bool) {
                                return .{ .tag = .boolean, .int_val = if (val) 1 else 0 };
                            } else if (finfo == .int) {
                                return .{ .tag = .int, .int_val = @intCast(val) };
                            } else if (finfo == .float) {
                                return .{ .tag = .float, .float_val = @floatCast(val) };
                            } else if (finfo == .pointer and finfo.pointer.size == .slice and finfo.pointer.child == u8) {
                                return .{ .tag = .string, .str_ptr = val.ptr, .str_len = val.len };
                            }
                        }
                    }
                }
                return .{ .tag = .none };
            }
        };

        const name = @typeName(T);
        return .{
            .ptr = @ptrCast(item),
            .len = 1,
            .element_size = @sizeOf(T),
            .element_align = @alignOf(T),
            .is_stream = false,
            .reflect_fn = &Trampoline.reflect,
            .repr = .typed,
            .schema_id = @import("lowered.zig").schemaId(T),
            .type_name_ptr = name.ptr,
            .type_name_len = name.len,
        };
    }

    pub fn fromSlice(comptime T: type, items: []const T) PayloadHandle_ABI {
        const Trampoline = struct {
            fn reflect(ptr: *const anyopaque, field_ptr: [*]const u8, field_len: usize) callconv(.c) ReflectedValue_ABI {
                const typed: [*]const T = @ptrCast(@alignCast(ptr));
                const field = field_ptr[0..field_len];
                const info = @typeInfo(T);
                if (info == .@"struct") {
                    inline for (info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, field)) {
                            const val = @field(&typed[0], f.name);
                            const finfo = @typeInfo(f.type);
                            if (finfo == .bool) {
                                return .{ .tag = .boolean, .int_val = if (val) 1 else 0 };
                            } else if (finfo == .int) {
                                return .{ .tag = .int, .int_val = @intCast(val) };
                            } else if (finfo == .float) {
                                return .{ .tag = .float, .float_val = @floatCast(val) };
                            } else if (finfo == .pointer and finfo.pointer.size == .slice and finfo.pointer.child == u8) {
                                return .{ .tag = .string, .str_ptr = val.ptr, .str_len = val.len };
                            }
                        }
                    }
                }
                return .{ .tag = .none };
            }
        };

        const name = @typeName(T);
        return .{
            .ptr = @ptrCast(items.ptr),
            .len = items.len,
            .element_size = @sizeOf(T),
            .element_align = @alignOf(T),
            .is_stream = true,
            .reflect_fn = if (items.len > 0) &Trampoline.reflect else null,
            .repr = .typed,
            .schema_id = @import("lowered.zig").schemaId(T),
            .type_name_ptr = name.ptr,
            .type_name_len = name.len,
        };
    }

    pub fn asSlice(self: PayloadHandle_ABI, comptime T: type) []const T {
        if (self.len == 0 or self.ptr == null) return &.{};
        const typed_ptr: [*]const T = @ptrCast(@alignCast(self.ptr.?));
        return typed_ptr[0..self.len];
    }

    pub fn asScalar(self: PayloadHandle_ABI, comptime T: type) *const T {
        return @ptrCast(@alignCast(self.ptr.?));
    }

    pub fn totalBytes(self: PayloadHandle_ABI) usize {
        if (self.len == 0 or self.ptr == null) return 0;
        return if (self.is_stream) self.len * self.element_size else self.element_size;
    }

    pub fn asBytes(self: PayloadHandle_ABI) []const u8 {
        const bytes_len = self.totalBytes();
        if (bytes_len == 0 or self.ptr == null) return &.{};
        const typed_ptr: [*]const u8 = @ptrCast(self.ptr.?);
        return typed_ptr[0..bytes_len];
    }
};
