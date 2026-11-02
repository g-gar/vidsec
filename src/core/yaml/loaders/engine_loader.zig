const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../../../lib/yaml/mod.zig");

pub const EngineLoadError = error{
    MissingSchemasPath,
};

pub const DbMode = enum {
    memory,
    wal_file,
};

pub const AllowedDirs = struct {
    quarantine: []const u8 = "/var/vidsec/quarantine",
    work: []const u8 = "/tmp/vidsec_work",
};

/// Decoded settings from the top-level `engine:` block in `pipeline.yaml`.
/// Automatically deserialized by `lib/yaml` via comptime struct reflection.
pub const EngineSettings = struct {
    schemas_path: []const u8,
    trace_file: ?[]const u8 = null,
    db_mode: DbMode = .memory,
    db_path: ?[]const u8 = null,
    db_busy_timeout_ms: u32 = 5000,
    max_task_memory_mb: u32 = 256,
    allowed_dirs: AllowedDirs = .{},

    pub const yaml_fields = .{
        .schemas_path = "schemas",
    };

    pub fn yamlValidate(self: *const EngineSettings, _: Allocator) EngineLoadError!void {
        if (self.schemas_path.len == 0) return error.MissingSchemasPath;
    }
};
