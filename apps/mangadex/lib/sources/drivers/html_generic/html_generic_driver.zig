const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("../../contract.zig");
const MangaSource = contract.MangaSource;
const SourceMangaSummary = contract.SourceMangaSummary;
const SourceSeriesDetails = contract.SourceSeriesDetails;
const SourceChapter = contract.SourceChapter;
const SourcePageUrl = contract.SourcePageUrl;

/// Placeholder / skeleton for Tier 1 HTML web scrapers.
/// Intended to be backed by Flowdata's OutboundAdapter and a lightweight parser.
pub const HtmlGenericSource = struct {
    source_id: []const u8 = "html_generic",
    base_url: []const u8 = "",

    comptime {
        MangaSource.assertImplements(@This());
    }

    pub fn init(source_id: []const u8, base_url: []const u8) HtmlGenericSource {
        return .{
            .source_id = source_id,
            .base_url = base_url,
        };
    }

    pub fn mangaSource(self: *HtmlGenericSource) MangaSource {
        return .{
            .ptr = self,
            .vtable = &.{
                .getSourceId = getSourceIdBridge,
                .search = searchBridge,
                .getDetails = getDetailsBridge,
                .getChapters = getChaptersBridge,
                .getPageUrls = getPageUrlsBridge,
                .canHandle = canHandleBridge,
            },
        };
    }

    fn getSourceIdBridge(ctx: *anyopaque) []const u8 {
        const self: *HtmlGenericSource = @ptrCast(@alignCast(ctx));
        return self.source_id;
    }

    fn canHandleBridge(ctx: *anyopaque, identifier: []const u8) bool {
        const self: *HtmlGenericSource = @ptrCast(@alignCast(ctx));
        if (self.base_url.len > 0 and std.mem.indexOf(u8, identifier, self.base_url) != null) {
            return true;
        }
        return false;
    }

    fn searchBridge(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]SourceMangaSummary {
        return error.NotImplemented;
    }

    fn getDetailsBridge(_: *anyopaque, _: Allocator, _: []const u8) anyerror!SourceSeriesDetails {
        return error.NotImplemented;
    }

    fn getChaptersBridge(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror![]SourceChapter {
        return error.NotImplemented;
    }

    fn getPageUrlsBridge(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]SourcePageUrl {
        return error.NotImplemented;
    }
};
