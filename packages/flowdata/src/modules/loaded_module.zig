const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("../abi/mod.zig");
const LoaderError = @import("loader_error.zig").LoaderError;

/// Represents a loaded module (backed either by an OS `std.DynLib` handle or a static/in-process manifest).
pub const LoadedModule = struct {
    alias_name: []const u8,
    manifest: *const abi.ModuleManifest_ABI,
    dyn_lib: ?std.DynLib = null,

    pub fn deinit(self: *LoadedModule, allocator: Allocator) void {
        allocator.free(self.alias_name);
        if (self.dyn_lib) |*lib| {
            lib.close();
        }
    }

    pub fn resolveTask(self: *const LoadedModule, task_name: ?[]const u8) LoaderError!*const abi.TaskDescriptor_ABI {
        return self.manifest.findTask(task_name) orelse error.UnknownTaskInModule;
    }
};
