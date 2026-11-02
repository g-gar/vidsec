const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../../../lib/yaml/mod.zig");

pub const OutputSpecError = error{
    ConflictingOutputTargets,
    MissingOutputTargetOrArtifact,
    MissingOutputKeyForMutationMode,
    InvalidOutputMap,
    EmptyOutputMap,
    OutOfMemory,
};

pub const OutputMutationMode = enum {
    insert,
    upsert,
    update,
};

/// Custom scalar type that distinguishes a constant literal (`"'R07'"`)
/// from a plugin-emitted field reference (`offset`).
pub const OutputFieldSource = union(enum) {
    constant_literal: []const u8,
    plugin_field: []const u8,

    pub fn yamlParseScalar(
        arena: Allocator,
        scalar: yaml.Scalar,
        _: yaml.SourceLoc,
    ) OutputSpecError!OutputFieldSource {
        const raw = scalar.value;
        if (raw.len == 0) return error.InvalidOutputMap;
        if (raw.len >= 2 and raw[0] == '\'' and raw[raw.len - 1] == '\'') {
            return .{ .constant_literal = try arena.dupe(u8, raw[1 .. raw.len - 1]) };
        }
        return .{ .plugin_field = try arena.dupe(u8, raw) };
    }
};

pub const TableOutputTarget = struct {
    table: []const u8,
    mode: OutputMutationMode = .insert,
    key_column: ?[]const u8 = null,
    fields: ?[]const []const u8 = null,
    map: ?yaml.Map(OutputFieldSource) = null,
};

pub const OutputTarget = union(enum) {
    schema_domain: []const u8,
    into_table: TableOutputTarget,
};

/// Decoded `output:` block for a task step.
pub const OutputSpec = struct {
    schema: ?[]const u8 = null,
    into: ?[]const u8 = null,
    mode: ?OutputMutationMode = null,
    key: ?[]const u8 = null,
    fields: ?[]const []const u8 = null,
    map: ?yaml.Map(OutputFieldSource) = null,
    artifact: ?[]const u8 = null,

    pub fn target(self: OutputSpec) ?OutputTarget {
        if (self.schema) |dom| {
            return .{ .schema_domain = dom };
        }
        if (self.into) |tbl| {
            return .{
                .into_table = .{
                    .table = tbl,
                    .mode = self.mode orelse .insert,
                    .key_column = self.key,
                    .fields = self.fields,
                    .map = self.map,
                },
            };
        }
        return null;
    }

    pub fn yamlValidate(self: *const OutputSpec, _: Allocator) OutputSpecError!void {
        if (self.schema != null and self.into != null) {
            return error.ConflictingOutputTargets;
        }
        if (self.schema) |dom| {
            if (dom.len == 0) return error.MissingOutputTargetOrArtifact;
            if (self.mode != null or self.key != null or self.fields != null or self.map != null) {
                return error.ConflictingOutputTargets;
            }
        }
        if (self.into) |tbl| {
            if (tbl.len == 0) return error.MissingOutputTargetOrArtifact;
            const effective_mode = self.mode orelse .insert;
            if ((effective_mode == .update or effective_mode == .upsert) and
                (self.key == null or self.key.?.len == 0))
            {
                return error.MissingOutputKeyForMutationMode;
            }
            if (self.fields != null and self.map != null) {
                return error.ConflictingOutputTargets;
            }
            if (self.fields) |f| {
                if (f.len == 0) return error.EmptyOutputMap;
            }
            if (self.map) |m| {
                if (m.count() == 0) return error.EmptyOutputMap;
            }
        }
        if (self.schema == null and self.into == null and
            (self.artifact == null or self.artifact.?.len == 0))
        {
            return error.MissingOutputTargetOrArtifact;
        }
    }
};
