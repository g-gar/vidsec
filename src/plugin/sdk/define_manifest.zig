const types = @import("../types/mod.zig");

const ModuleManifest_ABI = types.ModuleManifest_ABI;
const TaskDescriptor_ABI = types.TaskDescriptor_ABI;
const SemVer_ABI = types.SemVer_ABI;
const FLOWDATA_ABI_VERSION = types.FLOWDATA_ABI_VERSION;

/// Builds a `ModuleManifest_ABI` at compile time from a module name, semantic version, and slice of tasks.
pub fn defineManifest(
    comptime module_name: [:0]const u8,
    comptime version: SemVer_ABI,
    comptime tasks: []const TaskDescriptor_ABI,
) ModuleManifest_ABI {
    if (tasks.len == 0) {
        @compileError("ModuleManifest_ABI must expose at least one TaskDescriptor_ABI");
    }
    return .{
        .abi_version = FLOWDATA_ABI_VERSION,
        .module_name = module_name.ptr,
        .module_version = version,
        .tasks_ptr = tasks.ptr,
        .tasks_len = tasks.len,
    };
}
