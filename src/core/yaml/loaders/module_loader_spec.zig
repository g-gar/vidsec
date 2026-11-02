const Allocator = std.mem.Allocator;
const std = @import("std");
const yaml = @import("../../../lib/yaml/mod.zig");

pub const ModuleSpecError = error{
    MissingModulePath,
};

pub const ModuleDecl = struct {
    path: []const u8,

    pub fn yamlValidate(self: *const ModuleDecl, _: Allocator) ModuleSpecError!void {
        if (self.path.len == 0) return error.MissingModulePath;
    }
};

/// Map of `<module_name> -> ModuleDecl` decoded directly via `yaml.Map(ModuleDecl)`.
pub const ModuleDeclMap = yaml.Map(ModuleDecl);
