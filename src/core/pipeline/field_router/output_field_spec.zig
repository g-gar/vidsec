const std = @import("std");
const TargetDestination = @import("field_target.zig").TargetDestination;
const FieldTransform = @import("field_transform.zig").FieldTransform;
const FieldCast = @import("field_cast.zig").FieldCast;

/// Declarative specification for a first-class output field.
pub const OutputFieldSpec = struct {
    name: []const u8,
    target: TargetDestination = .both,
    as_name: ?[]const u8 = null,
    cast: FieldCast = .none,
    transform: FieldTransform = .none,
    round_decimals: ?u8 = null,

    pub fn destinationName(self: OutputFieldSpec) []const u8 {
        return self.as_name orelse self.name;
    }
};
