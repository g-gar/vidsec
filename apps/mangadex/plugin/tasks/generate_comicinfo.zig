const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const comicinfo = @import("comicinfo");
const ComicInfo = comicinfo.ComicInfo;
const MangaType = comicinfo.MangaType;

pub const GenerateComicInfoInputs = struct {
    series_title: ?[]const u8 = null,
    title: ?[]const u8 = null,
    chapter_number: ?[]const u8 = null,
    chapter_title: ?[]const u8 = null,
    volume_number: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    writer: ?[]const u8 = null,
    author: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    language: ?[]const u8 = "en",
    page_count: u32 = 0,
    manga_type: ?[]const u8 = null,
};

pub const ComicInfoOutput = struct {
    xml_data: []const u8,
};

/// Service that serializes metadata into Anansi ComicInfo XML format.
pub const GenerateComicInfoService = struct {
    logger: Logger,

    pub fn execute(self: *GenerateComicInfoService, alloc: Allocator, inputs: GenerateComicInfoInputs) !ComicInfoOutput {
        const resolved_title = if (inputs.series_title) |st|
            (if (st.len > 0) st else (inputs.title orelse "Unknown Manga"))
        else
            (inputs.title orelse "Unknown Manga");

        const resolved_writer = if (inputs.writer) |w|
            (if (w.len > 0) w else inputs.author)
        else
            inputs.author;

        self.logger.info("Generating ComicInfo.xml for series '{s}' (chapter: {s}, pages: {d})", .{
            resolved_title,
            inputs.chapter_number orelse "?",
            inputs.page_count,
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
            .title = inputs.chapter_title,
            .number = inputs.chapter_number,
            .volume = inputs.volume_number,
            .summary = inputs.summary,
            .writer = resolved_writer,
            .genre = inputs.genre,
            .page_count = inputs.page_count,
            .language_iso = inputs.language orelse "en",
            .manga = manga_enum,
        };

        const xml = try comicinfo.serialize(alloc, &info);

        return ComicInfoOutput{
            .xml_data = xml,
        };
    }
};
