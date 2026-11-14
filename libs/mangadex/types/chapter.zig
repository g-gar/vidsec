const std = @import("std");
const common = @import("common.zig");
const Relationship = common.Relationship;

pub const ChapterAttributes = struct {
    title: ?[]const u8 = null,
    volume: ?[]const u8 = null,
    chapter: ?[]const u8 = null,
    pages: u32 = 0,
    translatedLanguage: []const u8 = "en",
    uploader: ?[]const u8 = null,
    externalUrl: ?[]const u8 = null,
    version: ?u32 = null,
    createdAt: ?[]const u8 = null,
    updatedAt: ?[]const u8 = null,
    publishAt: ?[]const u8 = null,
    readableAt: ?[]const u8 = null,
};

pub const Chapter = struct {
    id: []const u8,
    type: []const u8 = "chapter",
    attributes: ChapterAttributes,
    relationships: []const Relationship = &.{},
};

pub const AggregateChapter = struct {
    chapter: []const u8,
    id: []const u8,
    others: []const []const u8 = &.{},
    count: u32 = 0,
};

pub const AggregateVolume = struct {
    volume: []const u8,
    count: u32 = 0,
    chapters: []const AggregateChapter = &.{},
};

pub const AggregateResponse = struct {
    result: []const u8 = "ok",
    volumes: std.json.Value,
};
