const std = @import("std");
const ir = @import("vidsec_ir");

/// Universal structural region (alias to `vidsec_ir.Region` to eliminate duplicate abstractions).
pub const ElementSpan = ir.Region;
pub const Region = ir.Region;
