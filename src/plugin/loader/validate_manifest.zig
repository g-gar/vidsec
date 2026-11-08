const std = @import("std");
const abi = @import("flowdata_plugin");
const LoaderError = @import("loader_error.zig").LoaderError;

/// Validates a `ModuleManifest_ABI` pointer for ABI version compatibility, non-empty task list,
/// and unique task names.
pub fn validateManifest(manifest: *const abi.ModuleManifest_ABI) LoaderError!void {
    if (manifest.abi_version != abi.FLOWDATA_ABI_VERSION) {
        return error.AbiVersionMismatch;
    }
    const tasks = manifest.tasksSlice();
    if (tasks.len == 0) {
        return error.EmptyModuleTaskList;
    }
    for (tasks, 0..) |t, i| {
        const name_i = t.nameSlice();
        if (name_i.len == 0) return error.EmptyModuleTaskList;
        for (tasks[0..i]) |prev| {
            if (std.mem.eql(u8, prev.nameSlice(), name_i)) {
                return error.DuplicateTaskNameInModule;
            }
        }
    }
}
