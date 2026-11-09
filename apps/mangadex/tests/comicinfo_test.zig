const std = @import("std");
const comicinfo = @import("comicinfo");
const ComicInfo = comicinfo.ComicInfo;
const ComicPageInfo = comicinfo.ComicPageInfo;

test "ComicInfo integration: serialize and parse roundtrip" {
    const allocator = std.testing.allocator;

    const pages = [_]ComicPageInfo{
        .{ .image_index = 0, .page_type = .FrontCover, .double_page = false },
        .{ .image_index = 1, .page_type = .Story, .double_page = false, .image_size_bytes = 54321 },
    };

    const info = ComicInfo{
        .title = "Chapter 1: Dawn of Adventure",
        .series = "One Piece",
        .number = "1",
        .summary = "Luffy sets sail to become King of the Pirates.",
        .writer = "Eiichiro Oda",
        .penciller = "Eiichiro Oda",
        .page_count = 2,
        .manga = .YesAndRightToLeft,
        .age_rating = .Teen,
        .pages = &pages,
    };

    const xml = try comicinfo.serialize(allocator, &info);
    defer allocator.free(xml);

    var parsed = try comicinfo.parse(allocator, xml);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("Chapter 1: Dawn of Adventure", parsed.title.?);
    try std.testing.expectEqualStrings("One Piece", parsed.series);
    try std.testing.expectEqualStrings("1", parsed.number.?);
    try std.testing.expectEqualStrings("Luffy sets sail to become King of the Pirates.", parsed.summary.?);
    try std.testing.expectEqual(@as(u32, 2), parsed.page_count);
    try std.testing.expectEqual(comicinfo.MangaType.YesAndRightToLeft, parsed.manga);
    try std.testing.expectEqual(comicinfo.AgeRating.Teen, parsed.age_rating);
    try std.testing.expectEqual(@as(usize, 2), parsed.pages.len);
    try std.testing.expectEqual(comicinfo.PageType.FrontCover, parsed.pages[0].page_type);
    try std.testing.expectEqual(comicinfo.PageType.Story, parsed.pages[1].page_type);
    try std.testing.expectEqual(@as(?u64, 54321), parsed.pages[1].image_size_bytes);
}
