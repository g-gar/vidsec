const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SourceMangaSummary = struct {
    source_id: []const u8,
    source_series_id: []const u8,
    title: []const u8,
    cover_url: ?[]const u8 = null,
};

pub const SourceSeriesDetails = struct {
    title: []const u8,
    alt_titles: []const []const u8 = &.{},
    available_languages: []const []const u8 = &.{},
    summary: ?[]const u8 = null,
    author: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    status: []const u8 = "ongoing",
    year: ?u16 = null,
    genres: []const []const u8 = &.{},
    cover_url: ?[]const u8 = null,
};

pub const SourceChapter = struct {
    source_chapter_id: []const u8,
    chapter_number: []const u8,
    volume_number: ?[]const u8 = null,
    title: ?[]const u8 = null,
    language_iso: []const u8,
    scanlation_group: ?[]const u8 = null,
};

pub const SourcePageUrl = struct {
    page_number: u32,
    url: []const u8,
    headers: []const [2][]const u8 = &.{},
};

pub const MangaSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getSourceId: *const fn (ctx: *anyopaque) []const u8,
        search: *const fn (ctx: *anyopaque, allocator: Allocator, query: []const u8) anyerror![]SourceMangaSummary,
        getDetails: *const fn (ctx: *anyopaque, allocator: Allocator, source_series_id: []const u8) anyerror!SourceSeriesDetails,
        getChapters: *const fn (ctx: *anyopaque, allocator: Allocator, source_series_id: []const u8, lang: []const u8) anyerror![]SourceChapter,
        getPageUrls: *const fn (ctx: *anyopaque, allocator: Allocator, source_chapter_id: []const u8) anyerror![]SourcePageUrl,
    };

    pub fn getSourceId(self: MangaSource) []const u8 {
        return self.vtable.getSourceId(self.ptr);
    }

    pub fn search(self: MangaSource, allocator: Allocator, query: []const u8) ![]SourceMangaSummary {
        return self.vtable.search(self.ptr, allocator, query);
    }

    pub fn getDetails(self: MangaSource, allocator: Allocator, source_series_id: []const u8) !SourceSeriesDetails {
        return self.vtable.getDetails(self.ptr, allocator, source_series_id);
    }

    pub fn getChapters(self: MangaSource, allocator: Allocator, source_series_id: []const u8, lang: []const u8) ![]SourceChapter {
        return self.vtable.getChapters(self.ptr, allocator, source_series_id, lang);
    }

    pub fn getPageUrls(self: MangaSource, allocator: Allocator, source_chapter_id: []const u8) ![]SourcePageUrl {
        return self.vtable.getPageUrls(self.ptr, allocator, source_chapter_id);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "mangaSource")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn mangaSource(*" ++ @typeName(T) ++ ") MangaSource'");
            }
        }
    }
};
