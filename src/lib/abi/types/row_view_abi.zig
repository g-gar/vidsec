const std = @import("std");
const Value_ABI = @import("value_abi.zig").Value_ABI;
const NamedField_ABI = @import("named_field_abi.zig").NamedField_ABI;

/// Read-only view of a single row yielded lazily by `HostApiVTable_ABI.next_row`.
/// Pointers remain valid until the next call to `next_row` on the same cursor or until task completion.
pub const RowView_ABI = extern struct {
    fields_ptr: [*]const NamedField_ABI,
    fields_len: usize,

    pub fn fieldsSlice(self: RowView_ABI) []const NamedField_ABI {
        if (self.fields_len == 0) return &.{};
        return self.fields_ptr[0..self.fields_len];
    }

    pub fn getField(self: RowView_ABI, target_name: []const u8) ?Value_ABI {
        for (self.fieldsSlice()) |f| {
            if (std.mem.eql(u8, f.nameSlice(), target_name)) {
                return f.value;
            }
        }
        return null;
    }

    pub fn into(self: RowView_ABI, comptime T: type) ?T {
        const type_info = @typeInfo(T);
        switch (type_info) {
            .@"struct" => |s| {
                var result: T = undefined;
                inline for (s.fields) |f| {
                    const maybe_field = self.getField(f.name);
                    if (maybe_field) |val| {
                        if (val.toAny(f.type)) |converted| {
                            @field(result, f.name) = converted;
                        } else {
                            if (f.default_value_ptr) |ptr| {
                                const default: *const f.type = @ptrCast(@alignCast(ptr));
                                @field(result, f.name) = default.*;
                            } else if (@typeInfo(f.type) == .optional) {
                                @field(result, f.name) = null;
                            } else {
                                return null;
                            }
                        }
                    } else {
                        if (f.default_value_ptr) |ptr| {
                            const default: *const f.type = @ptrCast(@alignCast(ptr));
                            @field(result, f.name) = default.*;
                        } else if (@typeInfo(f.type) == .optional) {
                            @field(result, f.name) = null;
                        } else {
                            return null;
                        }
                    }
                }
                return result;
            },
            else => @compileError("RowView_ABI.into expects a struct type"),
        }
    }
};
