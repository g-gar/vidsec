const std = @import("std");
const Allocator = std.mem.Allocator;

pub const AtHomeChapterData = struct {
    hash: []const u8,
    data: []const []const u8 = &.{},
    dataSaver: []const []const u8 = &.{},
};

pub const AtHomeServerResponse = struct {
    result: []const u8 = "ok",
    baseUrl: []const u8,
    chapter: AtHomeChapterData,
};

/// Constructs the full image URL from At-Home server response.
/// Standard mode: {baseUrl}/data/{hash}/{filename}
/// Data-saver mode: {baseUrl}/data-saver/{hash}/{filename}
pub fn buildPageUrl(
    allocator: Allocator,
    baseUrl: []const u8,
    data_saver: bool,
    hash: []const u8,
    filename: []const u8,
) ![]const u8 {
    const trimmed_base = std.mem.trimEnd(u8, baseUrl, "/");
    const mode = if (data_saver) "data-saver" else "data";
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{s}", .{
        trimmed_base,
        mode,
        hash,
        filename,
    });
}
