const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const MangaSource = @import("sources").MangaSource;

pub const FetchChapterPagesInputs = struct {
    source_chapter_id: []const u8,
    chapter_number: ?[]const u8 = null,
    series_id: ?[]const u8 = null,
    datasource: ?[]const u8 = null,
};

pub const ChapterPageItem = struct {
    source_chapter_id: []const u8,
    page_number: u32,
    url: []const u8,
};

pub const FetchChapterPagesService = struct {
    source: MangaSource,
    logger: Logger,

    pub fn execute(self: *FetchChapterPagesService, alloc: Allocator, inputs: FetchChapterPagesInputs) ![]ChapterPageItem {
        self.logger.info("Fetching pages for chapter '{s}' (chapter_number: {s}) via source '{s}'", .{
            inputs.source_chapter_id,
            inputs.chapter_number orelse "?",
            self.source.getSourceId(),
        });

        const pages = try self.source.getPageUrls(alloc, inputs.source_chapter_id);

        var page_list = try alloc.alloc(ChapterPageItem, pages.len);
        for (pages, 0..) |p, idx| {
            page_list[idx] = .{
                .source_chapter_id = inputs.source_chapter_id,
                .page_number = p.page_number,
                .url = p.url,
            };
        }

        self.logger.info("Total pages discovered for chapter '{s}': {d}", .{
            inputs.source_chapter_id,
            page_list.len,
        });
        return page_list;
    }
};
