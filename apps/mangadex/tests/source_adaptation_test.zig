const std = @import("std");
const sdk = @import("mangadex_sdk");
const sources = @import("mangadex_app").sources;
const MangaSource = sources.MangaSource;
const MangaDexSource = sources.MangaDexSource;
const MangaDexClient = sdk.MangaDexClient;
const HttpTransport = sdk.HttpTransport;
const HttpMethod = sdk.HttpMethod;
const HttpHeader = sdk.HttpHeader;
const HttpResponse = sdk.HttpResponse;
const HttpTransportError = sdk.HttpTransportError;

const MockSourceTransport = struct {
    pub fn httpTransport(self: *MockSourceTransport) HttpTransport {
        return .{
            .ptr = self,
            .vtable = &.{ .execute = executeBridge },
        };
    }

    fn executeBridge(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: HttpMethod,
        url: []const u8,
        _: []const HttpHeader,
        _: []const u8,
    ) HttpTransportError!HttpResponse {
        if (std.mem.indexOf(u8, url, "/manga/series-123/feed") != null) {
            const is_spanish = std.mem.indexOf(u8, url, "translatedLanguage[]=es-la") != null;
            if (is_spanish) {
                return .{
                    .status_code = 200,
                    .body =
                        \\{
                        \\  "result": "ok",
                        \\  "data": [
                        \\    {
                        \\      "id": "ch-101",
                        \\      "type": "chapter",
                        \\      "attributes": {
                        \\        "chapter": "1",
                        \\        "volume": "1",
                        \\        "title": "Capitulo Uno",
                        \\        "translatedLanguage": "es-la"
                        \\      },
                        \\      "relationships": [
                        \\        {
                        \\          "id": "group-1",
                        \\          "type": "scanlation_group",
                        \\          "attributes": { "name": "SpeedScans" }
                        \\        }
                        \\      ]
                        \\    }
                        \\  ]
                        \\}
                    ,
                };
            }

            return .{
                .status_code = 200,
                .body =
                    \\{
                    \\  "result": "ok",
                    \\  "data": [
                    \\    {
                    \\      "id": "ch-101",
                    \\      "type": "chapter",
                    \\      "attributes": {
                    \\        "chapter": "1",
                    \\        "volume": "1",
                    \\        "title": "Chapter One",
                    \\        "translatedLanguage": "en"
                    \\      },
                    \\      "relationships": [
                    \\        {
                    \\          "id": "group-1",
                    \\          "type": "scanlation_group",
                    \\          "attributes": { "name": "SpeedScans" }
                    \\        }
                    \\      ]
                    \\    }
                    \\  ]
                    \\}
                ,
            };
        }

        if (std.mem.indexOf(u8, url, "/manga/series-123") != null) {
            return .{
                .status_code = 200,
                .body =
                    \\{
                    \\  "result": "ok",
                    \\  "data": {
                    \\    "id": "series-123",
                    \\    "type": "manga",
                    \\    "attributes": {
                    \\      "title": { "en": "Grand Blue Dreaming" },
                    \\      "description": { "en": "A college comedy about diving and drinking." },
                    \\      "availableTranslatedLanguages": ["en", "es-la", "es"],
                    \\      "status": "ongoing",
                    \\      "year": 2014
                    \\    },
                    \\    "relationships": [
                    \\      {
                    \\        "id": "auth-1",
                    \\        "type": "author",
                    \\        "attributes": { "name": "Inoue Kenji" }
                    \\      },
                    \\      {
                    \\        "id": "art-1",
                    \\        "type": "artist",
                    \\        "attributes": { "name": "Yoshioka Kimitake" }
                    \\      }
                    \\    ]
                    \\  }
                    \\}
                ,
            };
        }

        if (std.mem.indexOf(u8, url, "/at-home/server/ch-101") != null) {
            return .{
                .status_code = 200,
                .body =
                    \\{
                    \\  "result": "ok",
                    \\  "baseUrl": "https://athome.mangadex.network",
                    \\  "chapter": {
                    \\    "hash": "hash101",
                    \\    "data": ["01.png", "02.png"]
                    \\  }
                    \\}
                ,
            };
        }

        if (std.mem.indexOf(u8, url, "/manga") != null) {
            return .{
                .status_code = 200,
                .body =
                    \\{
                    \\  "result": "ok",
                    \\  "data": [
                    \\    {
                    \\      "id": "series-123",
                    \\      "type": "manga",
                    \\      "attributes": {
                    \\        "title": { "en": "Grand Blue Dreaming", "es-la": "Gran Azul" }
                    \\      },
                    \\      "relationships": []
                    \\    }
                    \\  ]
                    \\}
                ,
            };
        }

        return .{
            .status_code = 404,
            .body = "{\"result\":\"error\"}",
        };
    }
};

test "MangaDexSource conforms to MangaSource interface and translates methods" {
    const allocator = std.testing.allocator;
    var mock = MockSourceTransport{};

    var client = MangaDexClient.init(
        allocator,
        .{},
        mock.httpTransport(),
        null,
    );

    var md_source = MangaDexSource.init(&client);
    const source: MangaSource = md_source.mangaSource();

    // 1. Source ID
    try std.testing.expectEqualStrings("mangadex", source.getSourceId());

    // 2. Search
    const search_results = try source.search(allocator, "Grand Blue");
    defer {
        for (search_results) |item| {
            allocator.free(item.source_series_id);
            allocator.free(item.title);
            if (item.cover_url) |c| allocator.free(c);
        }
        allocator.free(search_results);
    }
    try std.testing.expectEqual(@as(usize, 1), search_results.len);
    try std.testing.expectEqualStrings("series-123", search_results[0].source_series_id);
    try std.testing.expectEqualStrings("Grand Blue Dreaming", search_results[0].title);

    // 3. Details
    const details = try source.getDetails(allocator, "series-123");
    defer {
        allocator.free(details.title);
        for (details.alt_titles) |a| allocator.free(a);
        allocator.free(details.alt_titles);
        for (details.available_languages) |l| allocator.free(l);
        allocator.free(details.available_languages);
        if (details.summary) |s| allocator.free(s);
        if (details.author) |a| allocator.free(a);
        if (details.artist) |ar| allocator.free(ar);
        allocator.free(details.status);
        if (details.cover_url) |c| allocator.free(c);
    }
    try std.testing.expectEqualStrings("Grand Blue Dreaming", details.title);
    try std.testing.expectEqualStrings("Inoue Kenji", details.author.?);
    try std.testing.expectEqualStrings("Yoshioka Kimitake", details.artist.?);
    try std.testing.expectEqual(@as(?u16, 2014), details.year);
    // Verifies that MangaDex's available languages list is exposed to the task
    try std.testing.expectEqual(@as(usize, 3), details.available_languages.len);
    try std.testing.expectEqualStrings("es-la", details.available_languages[1]);

    // 4. Chapters
    const chapters = try source.getChapters(allocator, "series-123", "en");
    defer {
        for (chapters) |ch| {
            allocator.free(ch.source_chapter_id);
            allocator.free(ch.chapter_number);
            if (ch.volume_number) |v| allocator.free(v);
            if (ch.title) |t| allocator.free(t);
            allocator.free(ch.language_iso);
            if (ch.scanlation_group) |g| allocator.free(g);
        }
        allocator.free(chapters);
    }
    try std.testing.expectEqual(@as(usize, 1), chapters.len);
    try std.testing.expectEqualStrings("ch-101", chapters[0].source_chapter_id);
    try std.testing.expectEqualStrings("1", chapters[0].chapter_number);
    try std.testing.expectEqualStrings("SpeedScans", chapters[0].scanlation_group.?);

    // 5. Page URLs
    const pages = try source.getPageUrls(allocator, "ch-101");
    defer {
        for (pages) |p| {
            allocator.free(p.url);
        }
        allocator.free(pages);
    }
    try std.testing.expectEqual(@as(usize, 2), pages.len);
    try std.testing.expectEqual(@as(u32, 1), pages[0].page_number);
    try std.testing.expectEqualStrings("https://athome.mangadex.network/data/hash101/01.png", pages[0].url);
}

test "Plugin task inspects available languages and requests chapters in target language (e.g. Spanish es-la)" {
    const allocator = std.testing.allocator;
    var mock = MockSourceTransport{};

    var client = MangaDexClient.init(
        allocator,
        .{},
        mock.httpTransport(),
        null,
    );

    var md_source = MangaDexSource.init(&client);
    const source: MangaSource = md_source.mangaSource();

    // 1. Task inspects details to discover available languages
    const details = try source.getDetails(allocator, "series-123");
    defer {
        allocator.free(details.title);
        for (details.alt_titles) |a| allocator.free(a);
        allocator.free(details.alt_titles);
        for (details.available_languages) |l| allocator.free(l);
        allocator.free(details.available_languages);
        if (details.summary) |s| allocator.free(s);
        if (details.author) |a| allocator.free(a);
        if (details.artist) |ar| allocator.free(ar);
        allocator.free(details.status);
        if (details.cover_url) |c| allocator.free(c);
    }

    var has_spanish = false;
    for (details.available_languages) |l| {
        if (std.mem.eql(u8, l, "es-la") or std.mem.eql(u8, l, "es")) {
            has_spanish = true;
            break;
        }
    }
    try std.testing.expect(has_spanish);

    // 2. Task requests chapters specifically in Spanish ("es-la")
    const spanish_chapters = try source.getChapters(allocator, "series-123", "es-la");
    defer {
        for (spanish_chapters) |ch| {
            allocator.free(ch.source_chapter_id);
            allocator.free(ch.chapter_number);
            if (ch.volume_number) |v| allocator.free(v);
            if (ch.title) |t| allocator.free(t);
            allocator.free(ch.language_iso);
            if (ch.scanlation_group) |g| allocator.free(g);
        }
        allocator.free(spanish_chapters);
    }

    try std.testing.expectEqual(@as(usize, 1), spanish_chapters.len);
    try std.testing.expectEqualStrings("es-la", spanish_chapters[0].language_iso);
    try std.testing.expectEqualStrings("Capitulo Uno", spanish_chapters[0].title.?);
}
