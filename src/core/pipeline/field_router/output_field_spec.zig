const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../../../lib/yaml/mod.zig");
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

    pub fn parseFromYaml(
        arena: Allocator,
        node: yaml.Node,
        default_name: []const u8,
    ) !OutputFieldSpec {
        var spec = OutputFieldSpec{
            .name = try arena.dupe(u8, default_name),
        };

        if (node.asScalar()) |scalar| {
            if (TargetDestination.parse(scalar)) |dest| {
                spec.target = dest;
            } else if (std.mem.startsWith(u8, scalar, "db.") or std.mem.eql(u8, scalar, "db")) {
                spec.target = .repo;
            }
            return spec;
        }

        if (node.asMap()) |entries| {
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, "into") or
                    std.mem.eql(u8, entry.key, "target") or
                    std.mem.eql(u8, entry.key, "dest"))
                {
                    if (entry.value.asScalar()) |s| {
                        if (TargetDestination.parse(s)) |dest| {
                            spec.target = dest;
                        } else if (std.mem.startsWith(u8, s, "db.") or std.mem.eql(u8, s, "db")) {
                            spec.target = .repo;
                        }
                    }
                } else if (std.mem.eql(u8, entry.key, "as") or std.mem.eql(u8, entry.key, "name")) {
                    if (entry.value.asScalar()) |s| {
                        spec.as_name = try arena.dupe(u8, s);
                    }
                } else if (std.mem.eql(u8, entry.key, "cast")) {
                    if (entry.value.asScalar()) |s| {
                        spec.cast = FieldCast.parse(s);
                    }
                } else if (std.mem.eql(u8, entry.key, "transform")) {
                    if (entry.value.asScalar()) |s| {
                        if (std.mem.startsWith(u8, s, "round_decimals")) {
                            spec.transform = .round;
                            if (std.mem.indexOfScalar(u8, s, '(')) |open_idx| {
                                if (std.mem.indexOfScalar(u8, s, ')')) |close_idx| {
                                    const num_str = std.mem.trim(u8, s[open_idx + 1 .. close_idx], " ");
                                    spec.round_decimals = std.fmt.parseInt(u8, num_str, 10) catch 0;
                                }
                            }
                        } else {
                            spec.transform = FieldTransform.parse(s);
                        }
                    }
                } else if (std.mem.eql(u8, entry.key, "decimals") or std.mem.eql(u8, entry.key, "round_decimals")) {
                    if (entry.value.asScalar()) |s| {
                        spec.round_decimals = std.fmt.parseInt(u8, s, 10) catch null;
                    }
                }
            }
        }

        return spec;
    }
};
