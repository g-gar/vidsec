const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("../abi/mod.zig");
const LoaderError = @import("loader_error.zig").LoaderError;
const LoadedModule = @import("loaded_module.zig").LoadedModule;
const validateManifest = @import("validate_manifest.zig").validateManifest;
const verifySafeModulePermissions = @import("verify_safe_module_permissions.zig").verifySafeModulePermissions;

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
    ) LoaderError!*const abi.ModuleManifest_ABI {
        if (self.modules.contains(alias_name)) {
            return error.DuplicateModuleRegistration;
        }

        try verifySafeModulePermissions(self.allocator, so_path);

        var dyn_lib = std.DynLib.open(so_path) catch {
            return error.DynamicLibraryOpenFailed;
        };
        errdefer dyn_lib.close();

        const manifest_ptr = dyn_lib.lookup(*const abi.ModuleManifest_ABI, abi.MANIFEST_SYMBOL_NAME) orelse {
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
        manifest_ptr: *const abi.ModuleManifest_ABI,
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
    ) LoaderError!*const abi.TaskDescriptor_ABI {
        const mod = self.modules.getPtr(module_alias) orelse return error.UnknownModule;
        return mod.resolveTask(task_name);
    }
};
