const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../../../lib/yaml/mod.zig");
const TargetDestination = @import("../../pipeline/field_router/field_target.zig").TargetDestination;

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

/// Extracts a target table name from either a scalar (`"db.file_triage"`, `"file_triage"`)
/// or a map (`{ db: "ir_regions" }`).
pub fn extractPersistTable(arena: Allocator, node: yaml.Node) ?[]const u8 {
    if (node.asScalar()) |scalar| {
        if (std.mem.indexOfScalar(u8, scalar, '.')) |dot_idx| {
            return arena.dupe(u8, scalar[dot_idx + 1 ..]) catch null;
        }
        return arena.dupe(u8, scalar) catch null;
    }
    if (node.asMap()) |map| {
        for (map) |entry| {
            if (std.mem.eql(u8, entry.key, "db") or std.mem.eql(u8, entry.key, "sqlite")) {
                if (entry.value.asScalar()) |val| {
                    if (std.mem.indexOfScalar(u8, val, '.')) |dot_idx| {
                        return arena.dupe(u8, val[dot_idx + 1 ..]) catch null;
                    }
                    return arena.dupe(u8, val) catch null;
                }
            }
        }
    }
    return null;
}

/// Decoded `output:` block for a task step.
pub const OutputSpec = struct {
    schema: ?[]const u8 = null,
    into: ?[]const u8 = null,
    target_dest: ?TargetDestination = null,
    mode: ?OutputMutationMode = null,
    key: ?[]const u8 = null,
    fields: ?[]const []const u8 = null,
    map: ?yaml.Map(OutputFieldSource) = null,
    artifact: ?[]const u8 = null,

    pub const yaml_fields = .{
        .target_dest = "target",
    };

    pub fn yamlParse(
        arena: Allocator,
        node: yaml.Node,
        options: yaml.ParseOptions,
    ) anyerror!OutputSpec {
        const map = node.asMap() orelse return error.TypeMismatch;
        var schema: ?[]const u8 = null;
        var into: ?[]const u8 = null;
        var target_dest: ?TargetDestination = null;
        var mode: ?OutputMutationMode = null;
        var key: ?[]const u8 = null;
        var fields: ?[]const []const u8 = null;
        var out_map: ?yaml.Map(OutputFieldSource) = null;
        var artifact: ?[]const u8 = null;

        for (map) |entry| {
            if (std.mem.eql(u8, entry.key, "schema")) {
                schema = try arena.dupe(u8, entry.value.asScalar() orelse return error.InvalidOutputMap);
            } else if (std.mem.eql(u8, entry.key, "into")) {
                into = try arena.dupe(u8, entry.value.asScalar() orelse return error.InvalidOutputMap);
            } else if (std.mem.eql(u8, entry.key, "target")) {
                const raw = entry.value.asScalar() orelse return error.InvalidOutputMap;
                target_dest = try TargetDestination.yamlParseScalar(arena, .{ .value = raw, .quote_style = .plain }, .{ .line = 0, .column = 0 });
            } else if (std.mem.eql(u8, entry.key, "persist")) {
                if (extractPersistTable(arena, entry.value)) |tbl| {
                    into = tbl;
                }
            } else if (std.mem.eql(u8, entry.key, "mode")) {
                const raw = entry.value.asScalar() orelse return error.InvalidOutputMap;
                mode = std.meta.stringToEnum(OutputMutationMode, raw);
            } else if (std.mem.eql(u8, entry.key, "key")) {
                key = try arena.dupe(u8, entry.value.asScalar() orelse return error.InvalidOutputMap);
            } else if (std.mem.eql(u8, entry.key, "artifact")) {
                artifact = try arena.dupe(u8, entry.value.asScalar() orelse return error.InvalidOutputMap);
            } else if (std.mem.eql(u8, entry.key, "fields")) {
                fields = try yaml.parseFromNode([]const []const u8, arena, entry.value, options);
            } else if (std.mem.eql(u8, entry.key, "map")) {
                out_map = try yaml.parseFromNode(yaml.Map(OutputFieldSource), arena, entry.value, options);
            }
        }

        const spec = OutputSpec{
            .schema = schema,
            .into = into,
            .target_dest = target_dest,
            .mode = mode,
            .key = key,
            .fields = fields,
            .map = out_map,
            .artifact = artifact,
        };
        try spec.yamlValidate(arena);
        return spec;
    }

    pub fn target(self: OutputSpec) ?OutputTarget {
        if (self.target_dest) |dest| {
            if (dest == .memory) {
                return null;
            }
        }
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
        if (self.target_dest) |dest| {
            if (dest == .memory) {
                return;
            }
        }
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
