const std = @import("std");
const tika = @import("tika");

pub const Inputs = struct {
    identified_format: []const u8,
    canonical_extension: []const u8,
    declared_extension: []const u8 = "",
    strict_extension: bool = false,
};

pub const Outputs = struct {
    extension_match: bool,
    extension_violation: bool,
};

/// Validates whether `declared_extension` matches the detected `identified_format` (zero I/O).
pub const Service = struct {
    pub fn execute(_: *const Service, inputs: Inputs) !Outputs {
        const extension_match = if (inputs.declared_extension.len == 0)
            true
        else blk: {
            const format_id = std.meta.stringToEnum(tika.FormatId, inputs.identified_format) orelse .unknown;
            break :blk tika.types.matchesFormatExtension(format_id, inputs.canonical_extension, inputs.declared_extension);
        };

        return .{
            .extension_match = extension_match,
            .extension_violation = inputs.strict_extension and !extension_match,
        };
    }
};
