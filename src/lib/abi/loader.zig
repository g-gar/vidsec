const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

pub const VIDSEC_ABI_VERSION = types.VIDSEC_ABI_VERSION;
pub const MANIFEST_SYMBOL_NAME = types.MANIFEST_SYMBOL_NAME;
pub const ModuleManifest_ABI = types.ModuleManifest_ABI;
pub const TaskDescriptor_ABI = types.TaskDescriptor_ABI;

const c_stat = @cImport({
    @cInclude("sys/stat.h");
});

pub const LoaderError = error{
    ModuleFileNotFound,
    NotARegularFile,
    InsecureModulePermissions,
    DynamicLibraryOpenFailed,
    MissingManifestSymbol,
    AbiVersionMismatch,
    EmptyModuleTaskList,
    DuplicateTaskNameInModule,
    DuplicateModuleRegistration,
    UnknownModule,
    UnknownTaskInModule,
    OutOfMemory,
};

/// Validates a `ModuleManifest_ABI` pointer for ABI version compatibility, non-empty task list,
/// and unique task names.
pub fn validateManifest(manifest: *const ModuleManifest_ABI) LoaderError!void {
    if (manifest.abi_version != VIDSEC_ABI_VERSION) {
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

/// Verifies via POSIX `stat()` that the `.so` file at `path` exists, is a regular file,
/// and is NOT group-writable or world-writable (`(st_mode & 0o022) == 0`).
pub fn verifySafeModulePermissions(allocator: Allocator, path: []const u8) LoaderError!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var st: c_stat.struct_stat = undefined;
    if (c_stat.stat(path_z.ptr, &st) != 0) {
        return error.ModuleFileNotFound;
    }

    const file_type = st.st_mode & c_stat.S_IFMT;
    if (file_type != c_stat.S_IFREG) {
        return error.NotARegularFile;
    }

    // Reject group-writable (0o020) or world-writable (0o002) shared objects
    if ((st.st_mode & 0o022) != 0) {
        return error.InsecureModulePermissions;
    }
}

/// Represents a loaded module (backed either by an OS `std.DynLib` handle or a static/in-process manifest).
pub const LoadedModule = struct {
    alias_name: []const u8,
    manifest: *const ModuleManifest_ABI,
    dyn_lib: ?std.DynLib = null,

    pub fn deinit(self: *LoadedModule, allocator: Allocator) void {
        allocator.free(self.alias_name);
        if (self.dyn_lib) |*lib| {
            lib.close();
        }
    }

    pub fn resolveTask(self: *const LoadedModule, task_name: ?[]const u8) LoaderError!*const TaskDescriptor_ABI {
        return self.manifest.findTask(task_name) orelse error.UnknownTaskInModule;
    }
};

/// Registry and dynamic loader for `vidsec v2` plugin modules.
pub const ModuleRegistry = struct {
    allocator: Allocator,
    modules: std.StringHashMapUnmanaged(LoadedModule) = .{},

    pub fn init(allocator: Allocator) ModuleRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ModuleRegistry) void {
        var it = self.modules.valueIterator();
        while (it.next()) |mod| {
            mod.deinit(self.allocator);
        }
        self.modules.deinit(self.allocator);
    }

    /// Loads a `.so` plugin from `so_path`, enforcing permission checks (`mode & 0o022 == 0`),
    /// resolving `vidsec_module_manifest`, and validating `VIDSEC_ABI_VERSION`.
    pub fn loadSharedLibrary(
        self: *ModuleRegistry,
        alias_name: []const u8,
        so_path: []const u8,
    ) LoaderError!*const ModuleManifest_ABI {
        if (self.modules.contains(alias_name)) {
            return error.DuplicateModuleRegistration;
        }

        try verifySafeModulePermissions(self.allocator, so_path);

        var dyn_lib = std.DynLib.open(so_path) catch {
            return error.DynamicLibraryOpenFailed;
        };
        errdefer dyn_lib.close();

        const manifest_ptr = dyn_lib.lookup(*const ModuleManifest_ABI, MANIFEST_SYMBOL_NAME) orelse {
            return error.MissingManifestSymbol;
        };

        try validateManifest(manifest_ptr);

        const owned_alias = try self.allocator.dupe(u8, alias_name);
        errdefer self.allocator.free(owned_alias);

        try self.modules.put(self.allocator, owned_alias, .{
            .alias_name = owned_alias,
            .manifest = manifest_ptr,
            .dyn_lib = dyn_lib,
        });

        return manifest_ptr;
    }

    /// Registers an in-process or statically linked `ModuleManifest_ABI` under `alias_name`.
    pub fn registerStaticModule(
        self: *ModuleRegistry,
        alias_name: []const u8,
        manifest_ptr: *const ModuleManifest_ABI,
    ) LoaderError!void {
        if (self.modules.contains(alias_name)) {
            return error.DuplicateModuleRegistration;
        }

        try validateManifest(manifest_ptr);

        const owned_alias = try self.allocator.dupe(u8, alias_name);
        errdefer self.allocator.free(owned_alias);

        try self.modules.put(self.allocator, owned_alias, .{
            .alias_name = owned_alias,
            .manifest = manifest_ptr,
            .dyn_lib = null,
        });
    }

    pub fn getModule(self: *const ModuleRegistry, alias_name: []const u8) ?*const LoadedModule {
        return self.modules.getPtr(alias_name);
    }

    /// Resolves a task descriptor by module alias and optional task name (`null` selects default `tasks_ptr[0]`).
    pub fn resolveTask(
        self: *const ModuleRegistry,
        module_alias: []const u8,
        task_name: ?[]const u8,
    ) LoaderError!*const TaskDescriptor_ABI {
        const mod = self.modules.getPtr(module_alias) orelse return error.UnknownModule;
        return mod.resolveTask(task_name);
    }
};
