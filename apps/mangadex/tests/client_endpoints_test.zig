const std = @import("std");
const sdk = @import("mangadex_sdk");
const MangaDexClient = sdk.MangaDexClient;
const HttpTransport = sdk.HttpTransport;
const HttpMethod = sdk.HttpMethod;
const HttpHeader = sdk.HttpHeader;
const HttpResponse = sdk.HttpResponse;
const HttpTransportError = sdk.HttpTransportError;
const StaticTokenAuth = sdk.StaticTokenAuth;
const buildPageUrl = sdk.buildPageUrl;

const MockClientTransport = struct {
    last_auth_header: ?[]const u8 = null,

    pub fn httpTransport(self: *MockClientTransport) HttpTransport {
        return .{
            .ptr = self,
            .vtable = &.{ .execute = executeBridge },
        };
    }

    fn executeBridge(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        method: HttpMethod,
        url: []const u8,
        headers: []const HttpHeader,
        body: []const u8,
    ) HttpTransportError!HttpResponse {
        const self: *MockClientTransport = @ptrCast(@alignCast(ctx));
        _ = method;
        _ = body;

        for (headers) |h| {
            if (std.mem.eql(u8, h.name, "Authorization")) {
                if (self.last_auth_header) |existing| allocator.free(existing);
                self.last_auth_header = allocator.dupe(u8, h.value) catch return error.OutOfMemory;
            }
        }

        if (std.mem.indexOf(u8, url, "/ping") != null) {
            return .{
                .status_code = 200,
                .body = "pong",
            };
        }

        if (std.mem.indexOf(u8, url, "/at-home/server/chap-456") != null) {
            return .{
                .status_code = 200,
                .body =
                    \\{
                    \\  "result": "ok",
                    \\  "baseUrl": "https://athome.mangadex.network",
                    \\  "chapter": {
                    \\    "hash": "abc123hash",
                    \\    "data": ["01.png", "02.png"],
                    \\    "dataSaver": ["01.jpg", "02.jpg"]
                    \\  }
                    \\}
                ,
            };
        }

        if (std.mem.indexOf(u8, url, "/manga/manga-123/feed") != null or
            std.mem.indexOf(u8, url, "/user/follows/manga/feed") != null)
        {
            return .{
                .status_code = 200,
                .body =
                    \\{
                    \\  "result": "ok",
                    \\  "response": "collection",
                    \\  "data": [
                    \\    {
                    \\      "id": "chap-456",
                    \\      "type": "chapter",
                    \\      "attributes": {
                    \\        "title": "Prologue",
                    \\        "volume": "1",
                    \\        "chapter": "1",
                    \\        "pages": 2,
                    \\        "translatedLanguage": "en"
                    \\      },
                    \\      "relationships": []
                    \\    }
                    \\  ],
                    \\  "limit": 100,
                    \\  "offset": 0,
                    \\  "total": 1
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
                    \\  "response": "collection",
                    \\  "data": [
                    \\    {
                    \\      "id": "manga-123",
                    \\      "type": "manga",
                    \\      "attributes": {
                    \\        "title": { "en": "Test Manga Adventure" },
                    \\        "status": "ongoing",
                    \\        "year": 2024
                    \\      },
                    \\      "relationships": []
                    \\    }
                    \\  ],
                    \\  "limit": 10,
                    \\  "offset": 0,
                    \\  "total": 1
                    \\}
                ,
            };
        }

        return .{
            .status_code = 404,
            .body = "{\"result\":\"error\",\"errors\":[]}",
        };
    }

    pub fn deinit(self: *MockClientTransport, allocator: std.mem.Allocator) void {
        if (self.last_auth_header) |h| allocator.free(h);
    }
};

test "MangaDexClient ping healthcheck" {
    const allocator = std.testing.allocator;
    var mock = MockClientTransport{};
    defer mock.deinit(allocator);

    var client = MangaDexClient.init(
        allocator,
        .{},
        mock.httpTransport(),
        null,
    );

    const ok = try client.ping();
    try std.testing.expect(ok);
}

test "MangaDexClient end-to-end reader flow: search -> feed -> atHome -> pageUrl" {
    const allocator = std.testing.allocator;
    var mock = MockClientTransport{};
    defer mock.deinit(allocator);

    var client = MangaDexClient.init(
        allocator,
        .{},
        mock.httpTransport(),
        null,
    );

    // 1. Search Manga
    var search_res = try client.searchManga(.{ .title = "Test", .limit = 10 });
    defer search_res.deinit();

    try std.testing.expectEqual(@as(usize, 1), search_res.items.len);
    const manga_id = search_res.items[0].id;
    try std.testing.expectEqualStrings("manga-123", manga_id);

    // 2. Get Feed
    var feed_res = try client.getMangaFeed(manga_id, .{ .limit = 100 });
    defer feed_res.deinit();

    try std.testing.expectEqual(@as(usize, 1), feed_res.items.len);
    const chapter_id = feed_res.items[0].id;
    try std.testing.expectEqualStrings("chap-456", chapter_id);

    // 3. Get At-Home server URL
    var at_home_res = try client.getAtHomeServer(chapter_id, false);
    defer at_home_res.deinit();

    try std.testing.expectEqualStrings("https://athome.mangadex.network", at_home_res.baseUrl);
    try std.testing.expectEqualStrings("abc123hash", at_home_res.chapter.hash);
    try std.testing.expectEqual(@as(usize, 2), at_home_res.chapter.data.len);

    // 4. Build page URLs
    const page0_url = try buildPageUrl(
        allocator,
        at_home_res.baseUrl,
        false,
        at_home_res.chapter.hash,
        at_home_res.chapter.data[0],
    );
    defer allocator.free(page0_url);
    try std.testing.expectEqualStrings("https://athome.mangadex.network/data/abc123hash/01.png", page0_url);

    const data_saver_url = try buildPageUrl(
        allocator,
        at_home_res.baseUrl,
        true,
        at_home_res.chapter.hash,
        at_home_res.chapter.dataSaver[0],
    );
    defer allocator.free(data_saver_url);
    try std.testing.expectEqualStrings("https://athome.mangadex.network/data-saver/abc123hash/01.jpg", data_saver_url);
}

test "MangaDexClient injects Authorization header on authenticated endpoints" {
    const allocator = std.testing.allocator;
    var mock = MockClientTransport{};
    defer mock.deinit(allocator);

    var auth = try StaticTokenAuth.create(allocator, "jwt_super_token_999");
    defer auth.deinit();

    var client = MangaDexClient.init(
        allocator,
        .{},
        mock.httpTransport(),
        auth,
    );

    var res = try client.getUserFollowedMangaFeed(.{ .limit = 10 }, 5000);
    defer res.deinit();

    try std.testing.expect(mock.last_auth_header != null);
    try std.testing.expectEqualStrings("Bearer jwt_super_token_999", mock.last_auth_header.?);
}
