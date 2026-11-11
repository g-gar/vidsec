const std = @import("std");
const Slice_ABI = @import("slice_abi.zig").Slice_ABI;

/// Derives an ABI-stable mirror `extern struct` from a plain Zig struct type at compile time.
/// Replaces slices (`[]const u8`, `[]const T`) with C-ABI stable slice types and pointers,
/// normalizes booleans/enums, and ensures field order and alignment are deterministic across binaries.
pub fn Lowered(comptime T: type) type {
    const info = @typeInfo(T);
    switch (info) {
        .bool => return u8,
        .int => |int_info| {
            if (int_info.bits <= 8) return if (int_info.signedness == .signed) i8 else u8;
            if (int_info.bits <= 16) return if (int_info.signedness == .signed) i16 else u16;
            if (int_info.bits <= 32) return if (int_info.signedness == .signed) i32 else u32;
            if (int_info.bits <= 64) return if (int_info.signedness == .signed) i64 else u64;
            @compileError("Lowered(T): Integers wider than 64 bits are not supported across C-ABI: " ++ @typeName(T));
        },
        .float => |flt_info| {
            if (flt_info.bits == 32) return f32;
            if (flt_info.bits == 64) return f64;
            @compileError("Lowered(T): Unsupported float bit width: " ++ @typeName(T));
        },
        .@"enum" => |enum_info| {
            return enum_info.tag_type;
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                if (ptr_info.child == u8) {
                    return Slice_ABI;
                }
                const ElemLowered = Lowered(ptr_info.child);
                return extern struct {
                    ptr: ?[*]const ElemLowered = null,
                    len: usize = 0,

                    pub fn fromSlice(slice: []const ElemLowered) @This() {
                        return .{
                            .ptr = slice.ptr,
                            .len = slice.len,
                        };
                    }

                    pub fn asSlice(self: @This()) []const ElemLowered {
                        if (self.len == 0 or self.ptr == null) return &.{};
                        return self.ptr.?[0..self.len];
                    }
                };
            }
            @compileError("Lowered(T): Pointers other than slices are not permitted across C-ABI: " ++ @typeName(T));
        },
        .optional => |opt_info| {
            const ChildLowered = Lowered(opt_info.child);
            return extern struct {
                present: u8 = 0,
                value: ChildLowered = std.mem.zeroes(ChildLowered),

                pub fn fromOptional(opt: ?opt_info.child) @This() {
                    if (opt) |v| {
                        return .{
                            .present = 1,
                            .value = lowerValue(opt_info.child, v),
                        };
                    }
                    return .{ .present = 0, .value = std.mem.zeroes(ChildLowered) };
                }
            };
        },
        .@"struct" => |struct_info| {
            const fields = struct_info.fields;
            var field_names: [fields.len][:0]const u8 = undefined;
            var field_types: [fields.len]type = undefined;
            var field_attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;

            inline for (fields, 0..) |f, i| {
                const FieldLowered = Lowered(f.type);
                field_names[i] = f.name;
                field_types[i] = FieldLowered;
                field_attrs[i] = .{
                    .@"comptime" = f.is_comptime,
                    .@"align" = @alignOf(FieldLowered),
                };
            }

            return @Struct(.@"extern", null, &field_names, &field_types, &field_attrs);
        },
        else => @compileError("Lowered(T): Unsupported type for ABI lowering: " ++ @typeName(T)),
    }
}

/// Converts a native Zig value into its `Lowered(T)` C-ABI mirror.
pub fn lowerValue(comptime T: type, val: T) Lowered(T) {
    const info = @typeInfo(T);
    switch (info) {
        .bool => return if (val) 1 else 0,
        .int, .float => return val,
        .@"enum" => return @intFromEnum(val),
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                if (ptr_info.child == u8) {
                    return Slice_ABI.fromSlice(val);
                }
                return .{
                    .ptr = @ptrCast(val.ptr),
                    .len = val.len,
                };
            }
            unreachable;
        },
        .optional => |opt_info| {
            if (val) |v| {
                return .{
                    .present = 1,
                    .value = lowerValue(opt_info.child, v),
                };
            }
            return .{
                .present = 0,
                .value = std.mem.zeroes(Lowered(opt_info.child)),
            };
        },
        .@"struct" => |struct_info| {
            var lowered: Lowered(T) = undefined;
            inline for (struct_info.fields) |f| {
                @field(lowered, f.name) = lowerValue(f.type, @field(val, f.name));
            }
            return lowered;
        },
        else => unreachable,
    }
}

/// Lifts a `Lowered(T)` C-ABI value back into the native Zig `T` representation.
pub fn liftValue(comptime T: type, val: Lowered(T)) T {
    const info = @typeInfo(T);
    switch (info) {
        .bool => return val != 0,
        .int, .float => return val,
        .@"enum" => return @enumFromInt(val),
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                if (ptr_info.child == u8) {
                    return val.asSlice();
                }
                const Elem = ptr_info.child;
                const ElemLowered = Lowered(Elem);
                if (val.len == 0 or val.ptr == null) return &.{};
                if (@sizeOf(Elem) == @sizeOf(ElemLowered) and @alignOf(Elem) == @alignOf(ElemLowered)) {
                    const raw: [*]const Elem = @ptrCast(@alignCast(val.ptr.?));
                    return raw[0..val.len];
                }
                // When element layouts differ slightly, liftValue can be applied per item
                const raw: [*]const Elem = @ptrCast(@alignCast(val.ptr.?));
                return raw[0..val.len];
            }
            unreachable;
        },
        .optional => |opt_info| {
            if (val.present != 0) {
                return liftValue(opt_info.child, val.value);
            }
            return null;
        },
        .@"struct" => |struct_info| {
            var native: T = undefined;
            inline for (struct_info.fields) |f| {
                @field(native, f.name) = liftValue(f.type, @field(val, f.name));
            }
            return native;
        },
        else => unreachable,
    }
}

/// Computes a deterministic 64-bit Wyhash fingerprint of the schema of `T` at compile time.
/// Hash considers field names, field types, sizes, alignments, and struct offsets.
pub fn schemaId(comptime T: type) u64 {
    const Holder = struct {
        fn computeHash() u64 {
            @setEvalBranchQuota(100_000);
            var hasher = std.hash.Wyhash.init(0xdeadbeef_cafebabe);
            feedTypeHash(&hasher, T);
            return hasher.final();
        }

        fn feedTypeHash(hasher: anytype, comptime Target: type) void {
            const info = @typeInfo(Target);
            hasher.update(@typeName(Target));
            const size_val: usize = @sizeOf(Target);
            const align_val: usize = @alignOf(Target);
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
