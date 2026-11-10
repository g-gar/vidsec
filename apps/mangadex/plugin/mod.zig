const std = @import("std");
const flowdata = @import("flowdata");
const abi = flowdata.plugin;

// MangaDex plugin definitions for Flowdata pipeline execution
pub const plugin_version = "0.1.0";

pub const container = @import("container.zig");
pub const tasks = struct {
    pub const fetch_series_details = @import("tasks/fetch_series_details.zig");
    pub const fetch_chapters = @import("tasks/fetch_chapters.zig");
    pub const fetch_chapter_pages = @import("tasks/fetch_chapter_pages.zig");
};

pub const catalog = @import("catalog.zig");
pub const manifest = catalog.manifest;

comptime {
    @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
}
