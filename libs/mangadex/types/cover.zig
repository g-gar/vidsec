const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common.zig");
const Relationship = common.Relationship;

pub const CoverAttributes = struct {
    volume: ?[]const u8 = null,
    fileName: []const u8,
    description: ?[]const u8 = null,
    locale: ?[]const u8 = null,
    version: ?u32 = null,
    createdAt: ?[]const u8 = null,
    updatedAt: ?[]const u8 = null,
};

pub const Cover = struct {
    id: []const u8,
    type: []const u8 = "cover_art",
    attributes: CoverAttributes,
    relationships: []const Relationship = &.{},
};

pub const CoverQuality = enum {
    original,
    medium_512,
    small_256,
};

/// Builds the canonical cover art URL.
/// Full quality: https://uploads.mangadex.org/covers/{manga_id}/{file_name}
/// 512px: https://uploads.mangadex.org/covers/{manga_id}/{file_name}.512.jpg
/// 256px: https://uploads.mangadex.org/covers/{manga_id}/{file_name}.256.jpg
pub fn buildCoverUrl(
    allocator: Allocator,
    manga_id: []const u8,
    file_name: []const u8,
    quality: CoverQuality,
) ![]const u8 {
    return switch (quality) {
        .original => std.fmt.allocPrint(allocator, "https://uploads.mangadex.org/covers/{s}/{s}", .{ manga_id, file_name }),
        .medium_512 => std.fmt.allocPrint(allocator, "https://uploads.mangadex.org/covers/{s}/{s}.512.jpg", .{ manga_id, file_name }),
        .small_256 => std.fmt.allocPrint(allocator, "https://uploads.mangadex.org/covers/{s}/{s}.256.jpg", .{ manga_id, file_name }),
    };
}
