const std = @import("std");
const comicinfo = @import("comicinfo");
const ComicInfo = comicinfo.ComicInfo;
const ComicPageInfo = comicinfo.ComicPageInfo;

test "ComicInfo serialization escapes entities correctly" {
    const allocator = std.testing.allocator;

    const info = ComicInfo{
        .title = "Chapter 1: The \"Beginning\" & The End <Special>",
        .series = "Attack on Titan & Friends",
        .number = "1.5",
        .summary = "Synopsis with 'quotes' & <tags> & \"escapes\".",
        .writer = "Hajime Isayama & Assistant",
        .web = "https://mangadex.org/chapter/uuid?lang=en&translated=true",
        .page_count = 42,
        .manga = .YesAndRightToLeft,
        .age_rating = .Teen,
        .black_and_white = .Yes,
    };

    const xml = try comicinfo.serialize(allocator, &info);
    defer allocator.free(xml);

    try std.testing.expect(std.mem.startsWith(u8, xml, "<?xml version=\"1.0\" encoding=\"utf-8\"?>"));
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Title>Chapter 1: The &quot;Beginning&quot; &amp; The End &lt;Special&gt;</Title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Series>Attack on Titan &amp; Friends</Series>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Number>1.5</Number>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Summary>Synopsis with &apos;quotes&apos; &amp; &lt;tags&gt; &amp; &quot;escapes&quot;.</Summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Writer>Hajime Isayama &amp; Assistant</Writer>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Web>https://mangadex.org/chapter/uuid?lang=en&amp;translated=true</Web>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<PageCount>42</PageCount>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Manga>YesAndRightToLeft</Manga>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<AgeRating>Teen</AgeRating>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<BlackAndWhite>Yes</BlackAndWhite>") != null);
}

test "ComicInfo round-trip serialize and parse with pages" {
    const allocator = std.testing.allocator;

    const pages = [_]ComicPageInfo{
        .{ .image_index = 0, .page_type = .FrontCover, .double_page = false, .image_size_bytes = 102400 },
        .{ .image_index = 1, .page_type = .Story, .double_page = true, .image_size_bytes = 204800, .key = "page1_hash" },
        .{ .image_index = 2, .page_type = .BackCover, .double_page = false },
    };

    const original = ComicInfo{
        .title = "Thank You, Bonney",
        .series = "One Piece",
        .number = "1100",
        .count = 1200,
        .volume = "109",
        .alternate_series = "Wan Pīsu",
        .summary = "Kuma makes a deal with Saturn.",
        .notes = "Scraped from MangaDex.",
        .year = 2023,
        .month = 12,
        .day = 3,
        .writer = "Eiichiro Oda",
        .penciller = "Eiichiro Oda",
        .editor = "Weekly Shonen Jump",
        .translator = "TCB Scans",
        .publisher = "Shueisha",
        .imprint = "Jump Comics",
        .genre = "Action, Adventure, Fantasy",
        .tags = "Pirates, Superpowers",
        .web = "https://mangadex.org/chapter/1100",
        .page_count = 3,
        .language_iso = "en",
        .format = "Digital",
        .black_and_white = .No,
        .manga = .YesAndRightToLeft,
        .age_rating = .Teen,
        .pages = &pages,
    };

    const xml = try comicinfo.serialize(allocator, &original);
    defer allocator.free(xml);

    var parsed = try comicinfo.parse(allocator, xml);
    defer parsed.deinit(allocator);

    // Verify all fields matched
    try std.testing.expectEqualStrings(original.title.?, parsed.title.?);
    try std.testing.expectEqualStrings(original.series, parsed.series);
    try std.testing.expectEqualStrings(original.number.?, parsed.number.?);
    try std.testing.expectEqual(original.count.?, parsed.count.?);
    try std.testing.expectEqualStrings(original.volume.?, parsed.volume.?);
    try std.testing.expectEqualStrings(original.alternate_series.?, parsed.alternate_series.?);
    try std.testing.expectEqualStrings(original.summary.?, parsed.summary.?);
    try std.testing.expectEqualStrings(original.notes.?, parsed.notes.?);
    try std.testing.expectEqual(original.year.?, parsed.year.?);
    try std.testing.expectEqual(original.month.?, parsed.month.?);
    try std.testing.expectEqual(original.day.?, parsed.day.?);
    try std.testing.expectEqualStrings(original.writer.?, parsed.writer.?);
    try std.testing.expectEqualStrings(original.penciller.?, parsed.penciller.?);
    try std.testing.expectEqualStrings(original.editor.?, parsed.editor.?);
    try std.testing.expectEqualStrings(original.translator.?, parsed.translator.?);
    try std.testing.expectEqualStrings(original.publisher.?, parsed.publisher.?);
    try std.testing.expectEqualStrings(original.imprint.?, parsed.imprint.?);
    try std.testing.expectEqualStrings(original.genre.?, parsed.genre.?);
    try std.testing.expectEqualStrings(original.tags.?, parsed.tags.?);
    try std.testing.expectEqualStrings(original.web.?, parsed.web.?);
    try std.testing.expectEqual(original.page_count, parsed.page_count);
    try std.testing.expectEqualStrings(original.language_iso, parsed.language_iso);
    try std.testing.expectEqualStrings(original.format.?, parsed.format.?);
    try std.testing.expectEqual(original.black_and_white, parsed.black_and_white);
    try std.testing.expectEqual(original.manga, parsed.manga);
    try std.testing.expectEqual(original.age_rating, parsed.age_rating);

    // Verify pages
    try std.testing.expectEqual(@as(usize, 3), parsed.pages.len);
    try std.testing.expectEqual(@as(u32, 0), parsed.pages[0].image_index);
    try std.testing.expectEqual(comicinfo.PageType.FrontCover, parsed.pages[0].page_type);
    try std.testing.expectEqual(false, parsed.pages[0].double_page);
    try std.testing.expectEqual(@as(?u64, 102400), parsed.pages[0].image_size_bytes);

    try std.testing.expectEqual(@as(u32, 1), parsed.pages[1].image_index);
    try std.testing.expectEqual(comicinfo.PageType.Story, parsed.pages[1].page_type);
    try std.testing.expectEqual(true, parsed.pages[1].double_page);
    try std.testing.expectEqual(@as(?u64, 204800), parsed.pages[1].image_size_bytes);
    try std.testing.expectEqualStrings("page1_hash", parsed.pages[1].key.?);

    try std.testing.expectEqual(@as(u32, 2), parsed.pages[2].image_index);
    try std.testing.expectEqual(comicinfo.PageType.BackCover, parsed.pages[2].page_type);
}

test "ComicInfo parse handles XML comments and whitespace" {
    const allocator = std.testing.allocator;

    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<!-- Generated by Mihon / Komga -->
        \\<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema">
        \\  <Series>Berserk</Series>
        \\  <Number>001</Number>
        \\  <!-- Chapter details -->
        \\  <Title>The Black Swordsman</Title>
        \\  <Manga>YesAndRightToLeft</Manga>
        \\  <AgeRating>AdultsOnly</AgeRating>
        \\</ComicInfo>
    ;

    var parsed = try comicinfo.parse(allocator, xml);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("Berserk", parsed.series);
    try std.testing.expectEqualStrings("001", parsed.number.?);
    try std.testing.expectEqualStrings("The Black Swordsman", parsed.title.?);
    try std.testing.expectEqual(comicinfo.MangaType.YesAndRightToLeft, parsed.manga);
    try std.testing.expectEqual(comicinfo.AgeRating.AdultsOnly, parsed.age_rating);
}
