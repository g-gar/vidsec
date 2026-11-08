const std = @import("std");
const FLOWDATA_ABI_VERSION = @import("abi_version.zig").FLOWDATA_ABI_VERSION;
const SemVer_ABI = @import("semver_abi.zig").SemVer_ABI;
const TaskDescriptor_ABI = @import("task_descriptor_abi.zig").TaskDescriptor_ABI;

/// Top-level manifest exported by every `.so` plugin via the `flowdata_module_manifest` symbol.
pub const ModuleManifest_ABI = extern struct {
    abi_version: u32 = FLOWDATA_ABI_VERSION,
    module_name: [*:0]const u8,
    module_version: SemVer_ABI,
    tasks_ptr: [*]const TaskDescriptor_ABI,
    tasks_len: usize,

    pub fn nameSlice(self: ModuleManifest_ABI) []const u8 {
        return std.mem.span(self.module_name);
    }

    pub fn tasksSlice(self: ModuleManifest_ABI) []const TaskDescriptor_ABI {
        if (self.tasks_len == 0) return &.{};
        return self.tasks_ptr[0..self.tasks_len];
    }

    /// Resolves a task descriptor within this module:
    /// - When `task_name` is `null` (`use: <module_name>`), returns `&tasks_ptr[0]`.
    /// - When `task_name` is specified (`use: <module_name>/<task_name>`), finds the matching `TaskDescriptor_ABI`.
    pub fn findTask(self: *const ModuleManifest_ABI, task_name: ?[]const u8) ?*const TaskDescriptor_ABI {
        const tasks = self.tasksSlice();
        if (tasks.len == 0) return null;
        const target = task_name orelse return &tasks[0];
        for (tasks) |*t| {
            if (std.mem.eql(u8, t.nameSlice(), target)) {
                return t;
            }
        }
        return null;
    }
};
