const std = @import("std");
const Allocator = std.mem.Allocator;

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
    if (field_name.len == 0) {
        return reflectAny(T, item_ptr.*);
    }

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
            if (@hasDecl(T, "getParam")) {
                if (item_ptr.getParam(field_name)) |val| {
                    return ReflectedValue{ .string = val };
                }
            }
            if (@hasDecl(T, "getReflected")) {
                return item_ptr.getReflected(field_name);
            }
            return null;
        },
        else => return reflectAny(T, item_ptr.*),
    }
}

/// Reflectively extracts a dot-separated nested path (e.g. `container.header.codec_id`)
/// via direct compile-time struct offsets in O(1) without intermediate boxing (ARCH-018 §3.4).
pub fn reflectPath(comptime T: type, item_ptr: *const T, path: []const u8) ?ReflectedValue {
    const trimmed = std.mem.trim(u8, path, " \t");
    if (std.mem.indexOfScalar(u8, trimmed, '.')) |dot_idx| {
        const head = trimmed[0..dot_idx];
        const tail = trimmed[dot_idx + 1 ..];
        const info = @typeInfo(T);
        if (info == .@"struct") {
            inline for (info.@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, head)) {
                    const field_val = @field(item_ptr, f.name);
                    const finfo = @typeInfo(f.type);
                    if (finfo == .@"struct") {
                        return reflectPath(f.type, &field_val, tail);
                    } else if (finfo == .pointer and finfo.pointer.size == .one and @typeInfo(finfo.pointer.child) == .@"struct") {
                        return reflectPath(finfo.pointer.child, field_val, tail);
                    }
                }
            }
        }
        return null;
    }
    return reflectField(T, item_ptr, trimmed);
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

pub const ReflectFn = *const fn (ptr: *const anyopaque, field_name: []const u8) ?ReflectedValue;
pub const ContextualReflectFn = *const fn (ctx: *const anyopaque, ptr: *const anyopaque, field_name: []const u8) ?ReflectedValue;

pub const OpaqueReflectedValueAbi = extern struct {
    tag: u32 = 0,
    int_val: i64 = 0,
    float_val: f64 = 0.0,
    str_ptr: ?[*]const u8 = null,
    str_len: usize = 0,
};

pub const OpaqueReflectAbiFn = *const fn (ptr: *const anyopaque, field_ptr: [*]const u8, field_len: usize) callconv(.c) OpaqueReflectedValueAbi;

/// Computes a deterministic 64-bit Wyhash fingerprint of the schema of `Target` at compile time.
pub fn computeSchemaId(comptime Target: type) u64 {
    const Holder = struct {
        fn computeHash() u64 {
            @setEvalBranchQuota(100_000);
            var hasher = std.hash.Wyhash.init(0xdeadbeef_cafebabe);
            feedTypeHash(&hasher, Target);
            return hasher.final();
        }

        fn feedTypeHash(hasher: anytype, comptime T: type) void {
            const info = @typeInfo(T);
            hasher.update(@typeName(T));
            const size_val: usize = @sizeOf(T);
            const align_val: usize = @alignOf(T);
            hasher.update(std.mem.asBytes(&size_val));
            hasher.update(std.mem.asBytes(&align_val));

            switch (info) {
                .@"struct" => |s| {
                    hasher.update("struct");
                    inline for (s.fields) |f| {
                        hasher.update(f.name);
                        feedTypeHash(hasher, f.type);
                    }
                },
                .pointer => |p| {
                    if (p.size == .slice) {
                        hasher.update("slice");
                        feedTypeHash(hasher, p.child);
                    }
                },
                .optional => |o| {
                    hasher.update("optional");
                    feedTypeHash(hasher, o.child);
                },
                .@"enum" => |e| {
                    hasher.update("enum");
                    inline for (e.fields) |ef| {
                        hasher.update(ef.name);
                        const ev: i128 = ef.value;
                        hasher.update(std.mem.asBytes(&ev));
                    }
                },
                else => {},
            }
        }

        const id: u64 = computeHash();
    };
    return Holder.id;
}

pub const PayloadRepr = enum(u8) {
    bytes = 0,
    typed = 1,
    dynamic = 2,
};

/// Zero-copy type-erased fat pointer for transporting native Zig structs or streams
/// across pipeline task boundaries without allocating dynamic wrappers.
pub const PayloadHandle = struct {
    ptr: *const anyopaque,
    len: usize, // 1 if scalar, N if slice/stream
    is_stream: bool,
    type_name: []const u8,
    element_size: usize,
    element_align: u29,
    reflect_fn: ?ReflectFn = null,
    reflect_ctx: ?*const anyopaque = null,
    reflect_ctx_fn: ?ContextualReflectFn = null,
    abi_reflect_fn: ?OpaqueReflectAbiFn = null,
    repr: PayloadRepr = .bytes,
    schema_id: u64 = 0,

    pub fn fromScalar(comptime T: type, item: *const T) PayloadHandle {
        const Trampoline = struct {
            fn reflect(ptr: *const anyopaque, field: []const u8) ?ReflectedValue {
                const typed: *const T = @ptrCast(@alignCast(ptr));
                return reflectPath(T, typed, field);
            }

            fn reflectAbi(ptr: *const anyopaque, field_ptr: [*]const u8, field_len: usize) callconv(.c) OpaqueReflectedValueAbi {
                const typed: *const T = @ptrCast(@alignCast(ptr));
                const field = field_ptr[0..field_len];
                if (reflectPath(T, typed, field)) |val| {
                    return switch (val) {
                        .boolean => |b| .{ .tag = 4, .int_val = if (b) 1 else 0 },
                        .int => |iv| .{ .tag = 1, .int_val = iv },
                        .uint => |uv| .{ .tag = 2, .int_val = @bitCast(uv) },
                        .float => |fv| .{ .tag = 3, .float_val = fv },
                        .string => |sv| .{ .tag = 5, .str_ptr = sv.ptr, .str_len = sv.len },
                        else => .{ .tag = 0 },
                    };
                }
                return .{ .tag = 0 };
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
            .abi_reflect_fn = &Trampoline.reflectAbi,
            .repr = if (T == u8) .bytes else .typed,
            .schema_id = computeSchemaId(T),
        };
    }

    pub fn fromSlice(comptime T: type, items: []const T) PayloadHandle {
        const Trampoline = struct {
            fn reflect(ptr: *const anyopaque, field: []const u8) ?ReflectedValue {
                const typed: [*]const T = @ptrCast(@alignCast(ptr));
                return reflectPath(T, &typed[0], field);
            }

            fn reflectAbi(ptr: *const anyopaque, field_ptr: [*]const u8, field_len: usize) callconv(.c) OpaqueReflectedValueAbi {
                const typed: [*]const T = @ptrCast(@alignCast(ptr));
                const field = field_ptr[0..field_len];
                if (reflectPath(T, &typed[0], field)) |val| {
                    return switch (val) {
                        .boolean => |b| .{ .tag = 4, .int_val = if (b) 1 else 0 },
                        .int => |iv| .{ .tag = 1, .int_val = iv },
                        .uint => |uv| .{ .tag = 2, .int_val = @bitCast(uv) },
                        .float => |fv| .{ .tag = 3, .float_val = fv },
                        .string => |sv| .{ .tag = 5, .str_ptr = sv.ptr, .str_len = sv.len },
                        else => .{ .tag = 0 },
                    };
                }
                return .{ .tag = 0 };
            }
        };

        const is_dyn = (T == DynamicRecord);
        const is_raw_bytes = (T == u8);
        return .{
            .ptr = @ptrCast(items.ptr),
            .len = items.len,
            .is_stream = true,
            .type_name = @typeName(T),
            .element_size = @sizeOf(T),
            .element_align = @alignOf(T),
            .reflect_fn = if (items.len > 0) &Trampoline.reflect else null,
            .abi_reflect_fn = if (items.len > 0) &Trampoline.reflectAbi else null,
            .repr = if (is_raw_bytes) .bytes else if (is_dyn) .dynamic else .typed,
            .schema_id = computeSchemaId(T),
        };
    }

    pub fn empty() PayloadHandle {
        return .{
            .ptr = &.{},
            .len = 0,
            .is_stream = true,
            .type_name = "empty",
            .element_size = 0,
            .element_align = 1,
            .repr = .bytes,
        };
    }

    pub fn getReflected(self: PayloadHandle, field_name: []const u8) ?ReflectedValue {
        if (self.reflect_fn) |rf| {
            return rf(self.ptr, field_name);
        }
        if (self.reflect_ctx_fn) |rf_ctx| {
            if (self.reflect_ctx) |ctx| {
                return rf_ctx(ctx, self.ptr, field_name);
            }
        }
        return null;
    }

    /// Recursively retrieves a nested field along a dot-separated path (ARCH-018 §3.4).
    pub fn getReflectedPath(self: PayloadHandle, path: []const u8) ?ReflectedValue {
        return self.getReflected(path);
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
