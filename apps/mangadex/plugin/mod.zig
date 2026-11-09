const std = @import("std");
const flowdata = @import("flowdata");
const abi = flowdata.plugin;

// MangaDex plugin definitions for Flowdata pipeline execution
pub const plugin_version = "0.1.0";

pub const catalog = @import("catalog.zig");
pub const manifest = catalog.manifest;

comptime {
    @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
}
