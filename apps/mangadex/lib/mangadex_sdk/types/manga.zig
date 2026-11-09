const std = @import("std");
const common = @import("common.zig");
const LocalizedString = common.LocalizedString;
const Relationship = common.Relationship;

pub const TagAttributes = struct {
    name: LocalizedString,
    description: ?LocalizedString = null,
    group: ?[]const u8 = null,
    version: ?u32 = null,
};

pub const Tag = struct {
    id: []const u8,
    type: []const u8 = "tag",
    attributes: ?TagAttributes = null,
    relationships: []const Relationship = &.{},
};

pub const MangaAttributes = struct {
    title: LocalizedString,
    altTitles: []const LocalizedString = &.{},
    description: ?LocalizedString = null,
    isLocked: ?bool = null,
    originalLanguage: ?[]const u8 = null,
    lastVolume: ?[]const u8 = null,
    lastChapter: ?[]const u8 = null,
    publicationDemographic: ?[]const u8 = null,
    status: ?[]const u8 = null,
    year: ?u16 = null,
    contentRating: ?[]const u8 = null,
    tags: []const Tag = &.{},
    state: ?[]const u8 = null,
    chapterNumbersResetOnNewVolume: ?bool = null,
    availableTranslatedLanguages: []const []const u8 = &.{},
    createdAt: ?[]const u8 = null,
    updatedAt: ?[]const u8 = null,
    version: ?u32 = null,
    latestUploadedChapter: ?[]const u8 = null,
};

pub const Manga = struct {
    id: []const u8,
    type: []const u8 = "manga",
    attributes: MangaAttributes,
    relationships: []const Relationship = &.{},
};

pub const MangaSearchParams = struct {
    title: ?[]const u8 = null,
    limit: u32 = 10,
    offset: u32 = 0,
    authors: []const []const u8 = &.{},
    artists: []const []const u8 = &.{},
    year: ?u16 = null,
    includedTags: []const []const u8 = &.{},
    excludedTags: []const []const u8 = &.{},
    status: []const []const u8 = &.{},
    originalLanguage: []const []const u8 = &.{},
    excludedOriginalLanguage: []const []const u8 = &.{},
    availableTranslatedLanguage: []const []const u8 = &.{},
    publicationDemographic: []const []const u8 = &.{},
    ids: []const []const u8 = &.{},
    contentRating: []const []const u8 = &.{},
    includes: []const []const u8 = &.{},
};

pub const MangaFeedParams = struct {
    limit: u32 = 100,
    offset: u32 = 0,
    translatedLanguage: []const []const u8 = &.{},
    originalLanguage: []const []const u8 = &.{},
    excludedOriginalLanguage: []const []const u8 = &.{},
    contentRating: []const []const u8 = &.{},
    includes: []const []const u8 = &.{},
    order_chapter: ?[]const u8 = null,
};
