const std = @import("std");
const ir = struct {
    pub const RegionRole = @import("../../entities/region_role.zig").RegionRole;
};

/// Universal structural role (alias to `vidsec_ir.RegionRole` to eliminate duplicate abstractions).
pub const ElementRole = ir.RegionRole;
pub const RegionRole = ir.RegionRole;
