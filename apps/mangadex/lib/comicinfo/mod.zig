pub const schema = @import("schema.zig");
pub const writer = @import("writer.zig");
pub const reader = @import("reader.zig");

pub const ComicInfo = schema.ComicInfo;
pub const ComicPageInfo = schema.ComicPageInfo;
pub const YesNo = schema.YesNo;
pub const MangaType = schema.MangaType;
pub const AgeRating = schema.AgeRating;
pub const PageType = schema.PageType;

pub const ComicInfoWriter = writer.ComicInfoWriter;
pub const serialize = writer.ComicInfoWriter.serialize;
pub const escapeXml = writer.escapeXml;

pub const parse = reader.parse;
pub const unescapeXml = reader.unescapeXml;
