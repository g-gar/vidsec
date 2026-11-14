const std = @import("std");
const ir = struct {
    pub const Region = @import("../../entities/region.zig").Region;
};

/// Universal structural region (alias to `vidsec_ir.Region` to eliminate duplicate abstractions).
pub const ElementSpan = ir.Region;
pub const Region = ir.Region;
