pub const common = @import("common.zig");
pub const Uuid = common.Uuid;
pub const LocalizedString = common.LocalizedString;
pub const Relationship = common.Relationship;
pub const RelationshipType = common.RelationshipType;
pub const RelationshipAttr = common.RelationshipAttr;
pub const SortOrder = common.SortOrder;
pub const ApiError = common.ApiError;
pub const ErrorResponse = common.ErrorResponse;
pub const PagedResponse = common.PagedResponse;
pub const EntityResponse = common.EntityResponse;

pub const manga = @import("manga.zig");
pub const Manga = manga.Manga;
pub const MangaAttributes = manga.MangaAttributes;
pub const Tag = manga.Tag;
pub const TagAttributes = manga.TagAttributes;
pub const MangaSearchParams = manga.MangaSearchParams;
pub const MangaFeedParams = manga.MangaFeedParams;

pub const chapter = @import("chapter.zig");
pub const Chapter = chapter.Chapter;
pub const ChapterAttributes = chapter.ChapterAttributes;
pub const AggregateChapter = chapter.AggregateChapter;
pub const AggregateVolume = chapter.AggregateVolume;
pub const AggregateResponse = chapter.AggregateResponse;

pub const at_home = @import("at_home.zig");
pub const AtHomeChapterData = at_home.AtHomeChapterData;
pub const AtHomeServerResponse = at_home.AtHomeServerResponse;
pub const buildPageUrl = at_home.buildPageUrl;

pub const cover = @import("cover.zig");
pub const Cover = cover.Cover;
pub const CoverAttributes = cover.CoverAttributes;
pub const CoverQuality = cover.CoverQuality;
pub const buildCoverUrl = cover.buildCoverUrl;
