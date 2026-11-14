pub const sdk = @import("mangadex_sdk");
pub const komga_sdk = @import("komga_sdk");
pub const zip_archive = @import("zip_archive");
pub const comicinfo = @import("comicinfo");
pub const sources = @import("sources/mod.zig");
pub const adapters = @import("adapters/mod.zig");
pub const config = @import("config.zig");
pub const AppConfig = config.AppConfig;

pub const plugin_version = "0.1.0";
pub const container = @import("container.zig");
pub const tasks = struct {
    pub const fetch_series_details = @import("tasks/fetch_series_details.zig");
    pub const fetch_chapters = @import("tasks/fetch_chapters.zig");
    pub const fetch_chapter_pages = @import("tasks/fetch_chapter_pages.zig");
};
pub const catalog = @import("catalog.zig");
pub const manifest = catalog.manifest;
