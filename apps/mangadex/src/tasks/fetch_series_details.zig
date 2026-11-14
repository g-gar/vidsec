const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const MangaSource = @import("../sources/mod.zig").MangaSource;

pub const MangaJob = struct {
    series_id: []const u8,
    datasource: ?[]const u8 = null,
    languages: []const u8 = "en",
    chapters: []const u8 = "all",
    library: ?[]const u8 = null,
};

pub const SeriesDetails = struct {
    series_id: []const u8,
    source_id: []const u8 = "mangadex",
    title: []const u8,
    author: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    status: []const u8,
    year: ?i64 = null,
    cover_url: ?[]const u8 = null,
    available_languages: []const u8 = "",
    summary: ?[]const u8 = null,
    target_chapters: []const u8 = "all",
    library: ?[]const u8 = null,
};

pub const FetchSeriesDetailsService = struct {
    source: MangaSource,
    logger: Logger,

    pub fn execute(self: *FetchSeriesDetailsService, alloc: Allocator, job: MangaJob) !SeriesDetails {
        self.logger.info("Fetching series details for series_id={s} via source '{s}'", .{
            job.series_id,
            self.source.getSourceId(),
        });

        const details = try self.source.getDetails(alloc, job.series_id);

        var langs_buf: std.ArrayListUnmanaged(u8) = .empty;
        for (details.available_languages, 0..) |lang, idx| {
            if (idx > 0) try langs_buf.append(alloc, ',');
            try langs_buf.appendSlice(alloc, lang);
        }

        return SeriesDetails{
            .series_id = job.series_id,
            .source_id = self.source.getSourceId(),
            .title = details.title,
            .author = details.author,
            .artist = details.artist,
            .status = details.status,
            .year = if (details.year) |y| @intCast(y) else null,
            .cover_url = details.cover_url,
            .available_languages = langs_buf.items,
            .summary = details.summary,
            .target_chapters = job.chapters,
            .library = job.library,
        };
    }
};
