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
};

pub const ReflectFn_ABI = *const fn (
    ptr: *const anyopaque,
    field_ptr: [*]const u8,
    field_len: usize,
) callconv(.c) ReflectedValue_ABI;

/// C-ABI compliant zero-copy fat handle for passing typed items, slices, or raw byte streams
/// between host dataflow engine and dynamic plugin tasks.
pub const PayloadHandle_ABI = extern struct {
    ptr: ?*const anyopaque = null,
    len: usize = 0,
    element_size: usize = 0,
    element_align: u32 = 1,
    is_stream: bool = false,
    reflect_fn: ?ReflectFn_ABI = null,

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

        return .{
            .ptr = @ptrCast(item),
            .len = 1,
            .element_size = @sizeOf(T),
            .element_align = @alignOf(T),
            .is_stream = false,
            .reflect_fn = &Trampoline.reflect,
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

        return .{
            .ptr = @ptrCast(items.ptr),
            .len = items.len,
            .element_size = @sizeOf(T),
            .element_align = @alignOf(T),
            .is_stream = true,
            .reflect_fn = if (items.len > 0) &Trampoline.reflect else null,
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
