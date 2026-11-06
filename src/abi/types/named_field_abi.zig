const std = @import("std");
const Value_ABI = @import("value_abi.zig").Value_ABI;

/// Pair `(field_name, value)` emitted by a plugin (`emit_row`) or read from an input row cursor (`next_row`).
pub const NamedField_ABI = extern struct {
    name_ptr: [*:0]const u8,
    value: Value_ABI,

    pub fn init(name: [:0]const u8, value: Value_ABI) NamedField_ABI {
        return .{
            .name_ptr = name.ptr,
            .value = value,
        };
    }

    pub fn nameSlice(self: NamedField_ABI) []const u8 {
        return std.mem.span(self.name_ptr);
    }
};
