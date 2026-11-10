const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const MangaSource = @import("sources").MangaSource;

pub const FetchChaptersInputs = struct {
    series_id: []const u8,
    languages: []const u8 = "en",
    datasource: ?[]const u8 = null,
};

pub const ChapterItem = struct {
    source_chapter_id: []const u8,
    series_id: []const u8,
    chapter_number: []const u8,
    volume_number: ?[]const u8 = null,
    title: ?[]const u8 = null,
    language: []const u8,
    scanlation_group: ?[]const u8 = null,
};

pub const FetchChaptersService = struct {
    source: MangaSource,
    logger: Logger,

    pub fn execute(self: *FetchChaptersService, alloc: Allocator, inputs: FetchChaptersInputs) ![]ChapterItem {
        var chapters_list: std.ArrayListUnmanaged(ChapterItem) = .empty;

        var lang_iter = std.mem.tokenizeScalar(u8, inputs.languages, ',');
        while (lang_iter.next()) |raw_lang| {
            const lang = std.mem.trim(u8, raw_lang, " \t\r\n");
            if (lang.len == 0) continue;

            self.logger.info("Fetching chapters for series '{s}' in language '{s}' via source '{s}'", .{
                inputs.series_id,
                lang,
                self.source.getSourceId(),
            });
            const chapters = try self.source.getChapters(alloc, inputs.series_id, lang);
            for (chapters) |ch| {
                try chapters_list.append(alloc, .{
                    .source_chapter_id = ch.source_chapter_id,
                    .series_id = inputs.series_id,
                    .chapter_number = ch.chapter_number,
                    .volume_number = ch.volume_number,
                    .title = ch.title,
                    .language = ch.language_iso,
                    .scanlation_group = ch.scanlation_group,
                });
            }
        }

        self.logger.info("Total chapters discovered for series '{s}': {d}", .{
            inputs.series_id,
            chapters_list.items.len,
        });
        return chapters_list.toOwnedSlice(alloc);
    }
};
