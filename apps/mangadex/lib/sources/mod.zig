pub const contract = @import("contract.zig");
pub const MangaSource = contract.MangaSource;
pub const SourceMangaSummary = contract.SourceMangaSummary;
pub const SourceSeriesDetails = contract.SourceSeriesDetails;
pub const SourceChapter = contract.SourceChapter;
pub const SourcePageUrl = contract.SourcePageUrl;

pub const registry = @import("registry.zig");
pub const SourceRegistry = registry.SourceRegistry;

pub const drivers = struct {
    pub const mangadex = @import("drivers/mangadex/mangadex_driver.zig");
    pub const html_generic = @import("drivers/html_generic/html_generic_driver.zig");
};

pub const mangadex_source = drivers.mangadex;
pub const MangaDexSource = drivers.mangadex.MangaDexSource;
pub const HtmlGenericSource = drivers.html_generic.HtmlGenericSource;

test {
    _ = @import("registry.zig");
    _ = @import("drivers/mangadex/mangadex_driver.zig");
    _ = @import("drivers/html_generic/html_generic_driver.zig");
}
