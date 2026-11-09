const std = @import("std");
const reader = @import("../reader/mod.zig");
const types = @import("../types/mod.zig");
const TaskContext = @import("task_context.zig").TaskContext;
const SdkError = @import("sdk_error.zig").SdkError;

pub const InputInjectorError = error{
    MissingRequiredInput,
    TypeMismatch,
    OutOfMemory,
};

/// Populates and returns a strongly-typed `Inputs` struct by introspecting its fields
/// at compile time and resolving each from `ctx.getParam(...)` or `ctx.streamReader()`.
pub fn injectInputs(comptime Inputs: type, ctx: TaskContext) (SdkError || InputInjectorError)!Inputs {
    const info = @typeInfo(Inputs);
    if (info != .@"struct") {
        @compileError("Inputs must be a struct type, got " ++ @typeName(Inputs));
    }

    var inputs: Inputs = undefined;

    inline for (info.@"struct".fields) |field| {
        const key_z: [:0]const u8 = (field.name ++ "\x00")[0..field.name.len :0];
        @field(inputs, field.name) = try resolveField(field, ctx, key_z);
    }

    return inputs;
}

/// Resolves a single field value from context, applying defaults and type conversions.
fn resolveField(comptime field: std.builtin.Type.StructField, ctx: TaskContext, key_z: [:0]const u8) (SdkError || InputInjectorError)!field.type {
    const T = field.type;
    const has_default = (field.default_value_ptr != null);

    // 1. Direct Stream Reader injection
    if (T == reader.BoundedStreamReader) {
        return ctx.streamReader();
    }

    // 2. Struct injection (e.g. nested `job: struct { ... }`)
    if (@typeInfo(T) == .@"struct") {
        return injectInputs(T, ctx);
    }

    // 3. Fetch value from host context (checks both inputs: and params:)
    const maybe_val = try ctx.getParam(key_z);

    if (maybe_val) |val| {
        return try convertValue(T, val);
    }

    // 4. Fall back to compile-time struct default value if declared
    if (has_default) {
        const def_ptr = field.default_value_ptr.?;
        return @as(*const T, @ptrCast(@alignCast(def_ptr))).*;
    }

    // 5. Fall back to null for optional fields without explicit default
    if (@typeInfo(T) == .optional) {
        return null;
    }

    // 6. Missing required parameter
    ctx.logErrorFmt("Required input '{s}' is missing from task configuration", .{field.name});
    return error.MissingRequiredInput;
}

/// Converts a dynamic `Value_ABI` to the target compile-time type `T`.
fn convertValue(comptime T: type, val: types.Value_ABI) InputInjectorError!T {
    if (val.isNull()) {
        if (@typeInfo(T) == .optional) return null;
        return error.TypeMismatch;
    }

    switch (@typeInfo(T)) {
        .optional => |opt| {
            return try convertValue(opt.child, val);
        },
        .bool => {
            if (val.asBool()) |b| return b;
            if (val.asText()) |txt| {
                if (std.mem.eql(u8, txt, "true")) return true;
                if (std.mem.eql(u8, txt, "false")) return false;
            }
            return error.TypeMismatch;
        },
        .int => {
            if (val.asInt()) |raw| {
                return std.math.cast(T, raw) orelse error.TypeMismatch;
            }
            if (val.asText()) |txt| {
                const parsed = std.fmt.parseInt(T, txt, 10) catch return error.TypeMismatch;
                return parsed;
            }
            return error.TypeMismatch;
        },
        .float => {
            if (val.asFloat()) |raw| {
                return @floatCast(raw);
            }
            if (val.asText()) |txt| {
                const parsed = std.fmt.parseFloat(f64, txt) catch return error.TypeMismatch;
                return @floatCast(parsed);
            }
            return error.TypeMismatch;
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                return val.asText() orelse return error.TypeMismatch;
            }
            @compileError("Unsupported pointer type in task inputs: " ++ @typeName(T));
        },
        .@"enum" => |enum_info| {
            if (val.asInt()) |raw_int| {
                return std.meta.intToEnum(T, raw_int) catch error.TypeMismatch;
            }
            if (val.asText()) |raw_text| {
                inline for (enum_info.fields) |ef| {
                    if (std.mem.eql(u8, ef.name, raw_text)) {
                        return @enumFromInt(ef.value);
                    }
                }
                return error.TypeMismatch;
            }
            return error.TypeMismatch;
        },
        else => @compileError("Unsupported input field type: " ++ @typeName(T)),
    }
}

/// Computes the list of required parameter names for `Inputs` at compile time.
/// A field is required if it is not a stream, has no default value, and is not optional.
pub fn computeRequiredParams(comptime Inputs: type) []const [*:0]const u8 {
    const Holder = struct {
        fn getParams() []const [*:0]const u8 {
            const fields = @typeInfo(Inputs).@"struct".fields;
            var count: usize = 0;
            inline for (fields) |f| {
                if (f.type != reader.BoundedStreamReader and
                    f.default_value_ptr == null and
                    @typeInfo(f.type) != .optional)
                {
                    if (@typeInfo(f.type) == .@"struct") {
                        const sub_fields = @typeInfo(f.type).@"struct".fields;
                        inline for (sub_fields) |sf| {
                            if (sf.type != reader.BoundedStreamReader and
                                sf.default_value_ptr == null and
                                @typeInfo(sf.type) != .optional)
                            {
                                count += 1;
                            }
                        }
                    } else {
                        count += 1;
                    }
                }
            }

            var params: [count][*:0]const u8 = undefined;
            var idx: usize = 0;
            inline for (fields) |f| {
                if (f.type != reader.BoundedStreamReader and
                    f.default_value_ptr == null and
                    @typeInfo(f.type) != .optional)
                {
                    if (@typeInfo(f.type) == .@"struct") {
                        const sub_fields = @typeInfo(f.type).@"struct".fields;
                        inline for (sub_fields) |sf| {
                            if (sf.type != reader.BoundedStreamReader and
                                sf.default_value_ptr == null and
                                @typeInfo(sf.type) != .optional)
                            {
                                const sname_z: [:0]const u8 = (sf.name ++ "\x00")[0..sf.name.len :0];
                                params[idx] = sname_z.ptr;
                                idx += 1;
                            }
                        }
                    } else {
                        const name_z: [:0]const u8 = (f.name ++ "\x00")[0..f.name.len :0];
                        params[idx] = name_z.ptr;
                        idx += 1;
                    }
                }
            }
            const final_params = params;
            return &final_params;
        }

        const static_params = getParams();
    };

    return Holder.static_params;
}
