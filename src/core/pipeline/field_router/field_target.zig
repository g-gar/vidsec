const std = @import("std");

/// Destination target for an output field.
pub const TargetDestination = enum {
    memory,
    repo,
    both,

    pub fn parse(s: []const u8) ?TargetDestination {
        if (std.mem.eql(u8, s, "memory") or std.mem.eql(u8, s, "mem") or std.mem.eql(u8, s, "stream")) {
            return .memory;
        }
        if (std.mem.eql(u8, s, "repo") or std.mem.eql(u8, s, "db") or std.mem.eql(u8, s, "disk")) {
            return .repo;
        }
        if (std.mem.eql(u8, s, "both") or std.mem.eql(u8, s, "all")) {
            return .both;
        }
        return null;
    }

    pub fn includesMemory(self: TargetDestination) bool {
        return self == .memory or self == .both;
    }

    pub fn includesRepo(self: TargetDestination) bool {
        return self == .repo or self == .both;
    }

    pub fn yamlParseScalar(
        _: std.mem.Allocator,
        scalar: @import("../../../lib/yaml/mod.zig").Scalar,
        _: @import("../../../lib/yaml/mod.zig").SourceLoc,
    ) !TargetDestination {
        return TargetDestination.parse(scalar.value) orelse error.InvalidTargetDestination;
    }
};
