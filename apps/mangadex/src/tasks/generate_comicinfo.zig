const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const comicinfo = @import("comicinfo");
const ComicInfo = comicinfo.ComicInfo;
const MangaType = comicinfo.MangaType;
const ChapterItem = @import("fetch_chapters.zig").ChapterItem;

pub const GenerateComicInfoInputs = struct {
    item: ChapterItem,
    series_title: []const u8 = "",
    title: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    writer: ?[]const u8 = null,
    author: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    page_count: u32 = 0,
    manga_type: ?[]const u8 = null,
};

pub const ComicInfoOutput = struct {
    chapter_number: []const u8,
    xml_data: []const u8,
};

/// Service that serializes metadata into Anansi ComicInfo XML format per chapter.
pub const GenerateComicInfoService = struct {
    logger: Logger,

    pub fn execute(self: *GenerateComicInfoService, alloc: Allocator, inputs: GenerateComicInfoInputs) !ComicInfoOutput {
        const ch = inputs.item;
        const resolved_title = if (inputs.series_title.len > 0)
            inputs.series_title
        else
            (inputs.title orelse "Unknown Manga");

        const resolved_writer = if (inputs.writer) |w|
            (if (w.len > 0) w else inputs.author)
        else
            inputs.author;

        const resolved_page_count = if (inputs.page_count > 0) inputs.page_count else ch.page_count;

        self.logger.info("Generating ComicInfo.xml for series '{s}' (chapter: {s}, pages: {d})", .{
            resolved_title,
            ch.chapter_number,
            resolved_page_count,
        });

        var manga_enum: MangaType = .YesAndRightToLeft;
        if (inputs.manga_type) |mt| {
            if (std.mem.eql(u8, mt, "No")) {
                manga_enum = .No;
            } else if (std.mem.eql(u8, mt, "Yes")) {
                manga_enum = .Yes;
            } else if (std.mem.eql(u8, mt, "Unknown")) {
                manga_enum = .Unknown;
            }
        }

        const info = ComicInfo{
            .series = resolved_title,
            .title = ch.title,
            .number = ch.chapter_number,
            .volume = ch.volume_number,
            .summary = inputs.summary,
            .writer = resolved_writer,
            .genre = inputs.genre,
            .page_count = resolved_page_count,
            .language_iso = if (ch.language.len > 0) ch.language else "en",
            .manga = manga_enum,
        };

        const xml = try comicinfo.serialize(alloc, &info);

        return ComicInfoOutput{
            .chapter_number = ch.chapter_number,
            .xml_data = xml,
        };
    }
};
