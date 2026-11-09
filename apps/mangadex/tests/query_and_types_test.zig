const std = @import("std");
const sdk = @import("mangadex_sdk");
const QueryBuilder = sdk.QueryBuilder;
const types = sdk.types;
const Manga = types.Manga;
const Chapter = types.Chapter;
const PagedResponse = types.PagedResponse;
const LocalizedString = types.LocalizedString;

test "QueryBuilder builds bracketed array query string" {
    const allocator = std.testing.allocator;
    var qb = QueryBuilder.init(allocator);
    defer qb.deinit();

    try qb.addParam("limit", "10");
    try qb.addArrayParam("includes", &.{ "author", "cover_art" });
    try qb.addArrayParam("contentRating[]", &.{"safe"});

    const url = try qb.buildUrl("https://api.mangadex.org/manga");
    defer allocator.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, "https://api.mangadex.org/manga?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "limit=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "includes[]=author") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "includes[]=cover_art") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "contentRating[]=safe") != null);
}

test "JSON parsing of LocalizedString with preferred language fallback" {
    const allocator = std.testing.allocator;
    const json_data =
        \\{
        \\  "en": "Chainsaw Man",
        \\  "ja": "チェンソーマン",
        \\  "es-la": "El hombre motosierra"
        \\}
    ;

    const parsed = try std.json.parseFromSlice(
        LocalizedString,
        allocator,
        json_data,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("El hombre motosierra", parsed.value.get("es-la").?);
    try std.testing.expectEqualStrings("El hombre motosierra", parsed.value.getPreferred("es-la").?);
    try std.testing.expectEqualStrings("El hombre motosierra", parsed.value.getPreferred("es").?); // "es" dialect resolves "es-la"
    try std.testing.expectEqualStrings("チェンソーマン", parsed.value.getPreferred("ja").?);
    try std.testing.expectEqualStrings("Chainsaw Man", parsed.value.getPreferred("fr").?); // fallback to en
}

test "JSON parsing of Manga entity with Reference Expansion" {
    const allocator = std.testing.allocator;
    const json_data =
        \\{
        \\  "id": "a9667631-4ae3-4e4e-b549-7fed80f762d8",
        \\  "type": "manga",
        \\  "attributes": {
        \\    "title": { "en": "Sousou no Frieren", "ja": "葬送のフリーレン" },
        \\    "altTitles": [
        \\      { "en": "Frieren: Beyond Journey's End" }
        \\    ],
        \\    "description": { "en": "The adventure is over but life goes on for an elf mage..." },
        \\    "status": "ongoing",
        \\    "year": 2020,
        \\    "contentRating": "safe"
        \\  },
        \\  "relationships": [
        \\    {
        \\      "id": "11111111-2222-3333-4444-555555555555",
        \\      "type": "author",
        \\      "attributes": {
        \\        "name": "Yamada Kanehito"
        \\      }
        \\    },
        \\    {
        \\      "id": "66666666-7777-8888-9999-000000000000",
        \\      "type": "cover_art",
        \\      "attributes": {
        \\        "fileName": "frieren_vol1.jpg"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(
        Manga,
        allocator,
        json_data,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const m = parsed.value;
    try std.testing.expectEqualStrings("a9667631-4ae3-4e4e-b549-7fed80f762d8", m.id);
    try std.testing.expectEqualStrings("Sousou no Frieren", m.attributes.title.getPreferred("en").?);
    try std.testing.expectEqual(@as(?u16, 2020), m.attributes.year);
    try std.testing.expectEqual(@as(usize, 2), m.relationships.len);
    try std.testing.expectEqualStrings("author", m.relationships[0].type);
    try std.testing.expectEqualStrings("Yamada Kanehito", m.relationships[0].attributes.?.object.get("name").?.string);
    try std.testing.expectEqualStrings("cover_art", m.relationships[1].type);
    try std.testing.expectEqualStrings("frieren_vol1.jpg", m.relationships[1].attributes.?.object.get("fileName").?.string);
}
