const std = @import("std");
const ir = @import("vidsec_ir");

/// Universal structural role (alias to `vidsec_ir.RegionRole` to eliminate duplicate abstractions).
pub const ElementRole = ir.RegionRole;
pub const RegionRole = ir.RegionRole;
