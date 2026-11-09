const std = @import("std");

pub const CopyMode = enum {
    MOVE,
    COPY,
    HARDLINK,

    pub fn asText(self: CopyMode) []const u8 {
        return @tagName(self);
    }
};

pub const UserDto = struct {
    id: []const u8,
    email: []const u8,
    roles: []const []const u8 = &.{},
    sharedAllLibraries: bool = true,
};

pub const LibraryDto = struct {
    id: []const u8,
    name: []const u8,
    root: []const u8 = "",
    importComicInfoBook: bool = true,
    scanInterval: []const u8 = "",
    unavailable: bool = false,
};

pub const SeriesDto = struct {
    id: []const u8,
    libraryId: []const u8 = "",
    name: []const u8,
    booksCount: u32 = 0,
    deleted: bool = false,
};

pub const BookMediaDto = struct {
    status: []const u8 = "READY",
    pagesCount: u32 = 0,
};

pub const BookDto = struct {
    id: []const u8,
    seriesId: []const u8,
    name: []const u8,
    number: f32 = 0,
    sizeBytes: u64 = 0,
    media: BookMediaDto = .{},
    deleted: bool = false,
};

pub const BookImportDto = struct {
    seriesId: []const u8,
    sourceFile: []const u8,
    destinationName: ?[]const u8 = null,
    upgradeBookId: ?[]const u8 = null,
};

pub const BookImportBatchDto = struct {
    copyMode: CopyMode = .MOVE,
    books: []const BookImportDto,
};

pub fn PageDto(comptime T: type) type {
    return struct {
        content: []const T = &.{},
        empty: bool = true,
        first: bool = true,
        last: bool = true,
        number: u32 = 0,
        numberOfElements: u32 = 0,
        size: u32 = 20,
        totalElements: u64 = 0,
        totalPages: u32 = 0,
    };
}
