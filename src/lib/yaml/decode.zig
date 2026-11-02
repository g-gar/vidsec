const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

pub const Node = ast.Node;
pub const Scalar = ast.Scalar;
pub const QuoteStyle = ast.QuoteStyle;
pub const SourceLoc = ast.SourceLoc;
pub const MapEntry = ast.MapEntry;
pub const ScalarHook = ast.ScalarHook;

pub const DecodeError = error{
    TypeMismatch,
    MissingRequiredField,
    UnknownField,
    InvalidEnumTag,
    InvalidInteger,
    InvalidFloat,
    InvalidBoolean,
    ArrayLengthMismatch,
    NoMatchingUnionVariant,
    OutOfMemory,
};

pub const ParseOptions = struct {
    /// When false (default), any YAML map key not present in the target Zig `struct` returns `error.UnknownField`.
    ignore_unknown_fields: bool = false,
    /// When false (default), duplicate keys in the same YAML mapping return `error.DuplicateMapKey`.
    allow_duplicate_keys: bool = false,
    /// Optional scalar transformation hook (e.g. environment variable interpolation).
    scalar_hook: ?ScalarHook = null,

    pub fn toAstOptions(self: ParseOptions) ast.AstOptions {
        return .{
            .allow_duplicate_keys = self.allow_duplicate_keys,
            .scalar_hook = self.scalar_hook,
        };
    }
};

/// Generic ordered + hash-indexed dictionary for YAML mappings with dynamic user-defined keys
/// (e.g., `modules:`, `pipelines:`, `columns:`, `params:`, `map:`).
/// Automatically decoded by `parseFromNode` without writing custom parser boilerplate.
pub fn Map(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            key: []const u8,
            key_loc: SourceLoc,
            value: V,
        };

        entries: []const Entry = &.{},
        by_key: std.StringHashMapUnmanaged(V) = .{},

        pub fn count(self: Self) usize {
            return self.entries.len;
        }

        pub fn get(self: *const Self, key: []const u8) ?V {
            return self.by_key.get(key);
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.by_key.contains(key);
        }

        pub fn yamlParse(arena: Allocator, node: Node, options: ParseOptions) anyerror!Self {
            const raw_entries = node.asMap() orelse return error.TypeMismatch;
            var list: std.ArrayListUnmanaged(Entry) = .empty;
            var by_key: std.StringHashMapUnmanaged(V) = .empty;

            try list.ensureTotalCapacity(arena, raw_entries.len);
            for (raw_entries) |raw_entry| {
                const owned_key = try arena.dupe(u8, raw_entry.key);
                const parsed_val = try parseFromNode(V, arena, raw_entry.value, options);
                list.appendAssumeCapacity(.{
                    .key = owned_key,
                    .key_loc = raw_entry.key_loc,
                    .value = parsed_val,
                });
                try by_key.put(arena, owned_key, parsed_val);
            }

            return Self{
                .entries = try list.toOwnedSlice(arena),
                .by_key = by_key,
            };
        }
    };
}

/// Parses a YAML string directly into a Zig type `T` (primitive, struct, enum, union, slice, `Map(V)`,
/// or any custom type implementing `pub fn yamlParse` or `pub fn yamlParseScalar`).
pub fn parse(
    comptime T: type,
    arena: Allocator,
    source: []const u8,
    options: ParseOptions,
) anyerror!T {
    const root = try ast.parseAst(arena, source, options.toAstOptions());
    return parseFromNode(T, arena, root, options);
}

/// Decodes an untyped YAML `Node` into a target Zig type `T`.
pub fn parseFromNode(
    comptime T: type,
    arena: Allocator,
    node: Node,
    options: ParseOptions,
) anyerror!T {
    if (T == Node) return node;
    if (T == Scalar) return node.asScalarInfo() orelse error.TypeMismatch;

    // 1. Check custom deserialization hooks on user-defined types (`struct`, `union`, `enum`)
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {
            if (@hasDecl(T, "yamlParse")) {
                return T.yamlParse(arena, node, options);
            }
            if (@hasDecl(T, "yamlParseScalar")) {
                const scalar = node.asScalarInfo() orelse return error.TypeMismatch;
                return T.yamlParseScalar(arena, scalar, node.loc);
            }
        },
        else => {},
    }

    // 2. Standard comptime reflection decoding
    return switch (@typeInfo(T)) {
        .bool => parseBool(node),
        .int => parseInt(T, node),
        .float => parseFloat(T, node),
        .@"enum" => parseEnum(T, node),
        .optional => |opt_info| parseOptional(opt_info.child, arena, node, options),
        .pointer => |ptr_info| parsePointer(T, ptr_info, arena, node, options),
        .array => |arr_info| parseArray(T, arr_info.child, arr_info.len, arena, node, options),
        .@"struct" => parseStruct(T, arena, node, options),
        .@"union" => parseUnion(T, arena, node, options),
        else => @compileError("Unsupported YAML target type: " ++ @typeName(T)),
    };
}

fn parseBool(node: Node) DecodeError!bool {
    const raw = node.asScalar() orelse return error.TypeMismatch;
    if (std.mem.eql(u8, raw, "true")) return true;
    if (std.mem.eql(u8, raw, "false")) return false;
    return error.InvalidBoolean;
}

fn parseInt(comptime T: type, node: Node) DecodeError!T {
    const raw = node.asScalar() orelse return error.TypeMismatch;
    return std.fmt.parseInt(T, raw, 0) catch error.InvalidInteger;
}

fn parseFloat(comptime T: type, node: Node) DecodeError!T {
    const raw = node.asScalar() orelse return error.TypeMismatch;
    return std.fmt.parseFloat(T, raw) catch error.InvalidFloat;
}

fn parseEnum(comptime T: type, node: Node) DecodeError!T {
    const raw = node.asScalar() orelse return error.TypeMismatch;
    return std.meta.stringToEnum(T, raw) orelse error.InvalidEnumTag;
}

fn parseOptional(
    comptime Child: type,
    arena: Allocator,
    node: Node,
    options: ParseOptions,
) anyerror!?Child {
    if (node.asScalarInfo()) |scalar| {
        if (scalar.quote_style == .plain and
            (scalar.value.len == 0 or std.mem.eql(u8, scalar.value, "null") or std.mem.eql(u8, scalar.value, "~")))
        {
            return null;
        }
    }
    return try parseFromNode(Child, arena, node, options);
}

fn parsePointer(
    comptime T: type,
    comptime ptr_info: std.builtin.Type.Pointer,
    arena: Allocator,
    node: Node,
    options: ParseOptions,
) anyerror!T {
    switch (ptr_info.size) {
        .slice => {
            if (ptr_info.child == u8) {
                const raw = node.asScalar() orelse return error.TypeMismatch;
                if (ptr_info.sentinel()) |sentinel_val| {
                    if (sentinel_val == 0) {
                        return try arena.dupeZ(u8, raw);
                    }
                }
                return try arena.dupe(u8, raw);
            }

            const seq = node.asSeq() orelse return error.TypeMismatch;
            const out = try arena.alloc(ptr_info.child, seq.len);
            for (seq, 0..) |item_node, idx| {
                out[idx] = try parseFromNode(ptr_info.child, arena, item_node, options);
            }
            return out;
        },
        .one => {
            const ptr = try arena.create(ptr_info.child);
            ptr.* = try parseFromNode(ptr_info.child, arena, node, options);
            return ptr;
        },
        else => @compileError("Unsupported pointer type in YAML decoder: " ++ @typeName(T)),
    }
}

fn parseArray(
    comptime T: type,
    comptime Child: type,
    comptime len: usize,
    arena: Allocator,
    node: Node,
    options: ParseOptions,
) anyerror!T {
    const seq = node.asSeq() orelse return error.TypeMismatch;
    if (seq.len != len) return error.ArrayLengthMismatch;

    var out: T = undefined;
    for (seq, 0..) |item_node, idx| {
        out[idx] = try parseFromNode(Child, arena, item_node, options);
    }
    return out;
}

fn parseStruct(
    comptime T: type,
    arena: Allocator,
    node: Node,
    options: ParseOptions,
) anyerror!T {
    const entries = node.asMap() orelse return error.TypeMismatch;
    const struct_info = @typeInfo(T).@"struct";

    if (!options.ignore_unknown_fields) {
        for (entries) |entry| {
            if (!structHasYamlKey(T, entry.key)) {
                return error.UnknownField;
            }
        }
    }

    var result: T = undefined;

    inline for (struct_info.fields) |field| {
        const yaml_key = comptime yamlKeyForField(T, field.name);
        if (node.get(yaml_key)) |field_node| {
            @field(result, field.name) = try parseFromNode(field.type, arena, field_node, options);
        } else if (field.default_value_ptr) |default_ptr| {
            const typed_default: *const field.type = @ptrCast(@alignCast(default_ptr));
            @field(result, field.name) = typed_default.*;
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            return error.MissingRequiredField;
        }
    }

    if (@hasDecl(T, "yamlValidate")) {
        try result.yamlValidate(arena);
    }

    return result;
}

fn parseUnion(
    comptime T: type,
    arena: Allocator,
    node: Node,
    options: ParseOptions,
) anyerror!T {
    const union_info = @typeInfo(T).@"union";
    if (union_info.tag_type == null) {
        @compileError("Untagged unions require a custom `yamlParse` method: " ++ @typeName(T));
    }

    // Attempt each union variant in declaration order
    inline for (union_info.fields) |field| {
        if (field.type == void) {
            if (node.asScalar()) |s| {
                if (std.mem.eql(u8, s, field.name)) {
                    return @unionInit(T, field.name, {});
                }
            }
        } else {
            if (parseFromNode(field.type, arena, node, options)) |val| {
                return @unionInit(T, field.name, val);
            } else |_| {}
        }
    }

    return error.NoMatchingUnionVariant;
}

fn yamlKeyForField(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (@hasDecl(T, "yaml_fields")) {
        const mapping = T.yaml_fields;
        if (@hasField(@TypeOf(mapping), field_name)) {
            return @field(mapping, field_name);
        }
    }
    return field_name;
}

fn structHasYamlKey(comptime T: type, runtime_key: []const u8) bool {
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.fields) |field| {
        const expected = comptime yamlKeyForField(T, field.name);
        if (std.mem.eql(u8, runtime_key, expected)) return true;
    }
    return false;
}
