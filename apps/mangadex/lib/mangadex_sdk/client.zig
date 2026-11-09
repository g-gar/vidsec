const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const HttpTransport = http.HttpTransport;
const HttpMethod = http.HttpMethod;
const HttpHeader = http.HttpHeader;
const QueryBuilder = http.QueryBuilder;
const auth_mod = @import("auth/mod.zig");
const AuthProvider = auth_mod.AuthProvider;
const types = @import("types/mod.zig");
const Manga = types.Manga;
const MangaSearchParams = types.MangaSearchParams;
const MangaFeedParams = types.MangaFeedParams;
const Chapter = types.Chapter;
const Cover = types.Cover;
const AggregateResponse = types.AggregateResponse;
const AtHomeServerResponse = types.AtHomeServerResponse;
const AtHomeChapterData = types.AtHomeChapterData;
const PagedResponse = types.PagedResponse;
const EntityResponse = types.EntityResponse;

pub const ClientConfig = struct {
    api_url: []const u8 = "https://api.mangadex.org",
    user_agent: []const u8 = "mangadex-sdk-zig/0.1.0",
};

pub const ClientError = error{
    HttpError,
    NotFound,
    Unauthorized,
    RateLimited,
    Timeout,
    InvalidUrl,
    NetworkFailure,
    JsonParseError,
    OutOfMemory,
};

pub fn PagedResult(comptime T: type) type {
    return struct {
        parsed: std.json.Parsed(PagedResponse(T)),
        items: []const T,
        total: u32,
        limit: u32,
        offset: u32,

        pub fn deinit(self: *@This()) void {
            self.parsed.deinit();
        }
    };
}

pub fn EntityResult(comptime T: type) type {
    return struct {
        parsed: std.json.Parsed(EntityResponse(T)),
        data: T,

        pub fn deinit(self: *@This()) void {
            self.parsed.deinit();
        }
    };
}

pub const AtHomeResult = struct {
    parsed: std.json.Parsed(AtHomeServerResponse),
    baseUrl: []const u8,
    chapter: AtHomeChapterData,

    pub fn deinit(self: *@This()) void {
        self.parsed.deinit();
    }
};

pub const MangaDexClient = struct {
    allocator: Allocator,
    config: ClientConfig,
    transport: HttpTransport,
    auth: ?AuthProvider = null,

    pub fn init(
        allocator: Allocator,
        config: ClientConfig,
        transport: HttpTransport,
        auth: ?AuthProvider,
    ) MangaDexClient {
        return .{
            .allocator = allocator,
            .config = config,
            .transport = transport,
            .auth = auth,
        };
    }

    pub fn ping(self: *MangaDexClient) ClientError!bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/ping", .{self.config.api_url});
        defer self.allocator.free(url);

        const res = self.sendRequest(.GET, url, null, "") catch |err| return err;
        return res.status_code == 200 and std.mem.indexOf(u8, res.body, "pong") != null;
    }

    pub fn searchManga(self: *MangaDexClient, params: MangaSearchParams) ClientError!PagedResult(Manga) {
        var qb = QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.addInt("limit", params.limit);
        try qb.addInt("offset", params.offset);
        if (params.title) |t| try qb.addParam("title", t);
        if (params.year) |y| try qb.addInt("year", y);
        try qb.addArrayParam("authors", params.authors);
        try qb.addArrayParam("artists", params.artists);
        try qb.addArrayParam("includedTags", params.includedTags);
        try qb.addArrayParam("excludedTags", params.excludedTags);
        try qb.addArrayParam("status", params.status);
        try qb.addArrayParam("originalLanguage", params.originalLanguage);
        try qb.addArrayParam("excludedOriginalLanguage", params.excludedOriginalLanguage);
        try qb.addArrayParam("availableTranslatedLanguage", params.availableTranslatedLanguage);
        try qb.addArrayParam("publicationDemographic", params.publicationDemographic);
        try qb.addArrayParam("ids", params.ids);
        try qb.addArrayParam("contentRating", params.contentRating);
        try qb.addArrayParam("includes", params.includes);

        const base_url = try std.fmt.allocPrint(self.allocator, "{s}/manga", .{self.config.api_url});
        defer self.allocator.free(base_url);

        const full_url = try qb.buildUrl(base_url);
        defer self.allocator.free(full_url);

        const res = try self.sendRequest(.GET, full_url, null, "");
        const parsed = std.json.parseFromSlice(
            PagedResponse(Manga),
            self.allocator,
            res.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.JsonParseError;

        return .{
            .parsed = parsed,
            .items = parsed.value.data,
            .total = parsed.value.total,
            .limit = parsed.value.limit,
            .offset = parsed.value.offset,
        };
    }

    pub fn getManga(self: *MangaDexClient, manga_id: []const u8, includes: []const []const u8) ClientError!EntityResult(Manga) {
        var qb = QueryBuilder.init(self.allocator);
        defer qb.deinit();
        try qb.addArrayParam("includes", includes);

        const base_url = try std.fmt.allocPrint(self.allocator, "{s}/manga/{s}", .{ self.config.api_url, manga_id });
        defer self.allocator.free(base_url);

        const full_url = try qb.buildUrl(base_url);
        defer self.allocator.free(full_url);

        const res = try self.sendRequest(.GET, full_url, null, "");
        const parsed = std.json.parseFromSlice(
            EntityResponse(Manga),
            self.allocator,
            res.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.JsonParseError;

        return .{
            .parsed = parsed,
            .data = parsed.value.data,
        };
    }

    pub fn getMangaFeed(self: *MangaDexClient, manga_id: []const u8, params: MangaFeedParams) ClientError!PagedResult(Chapter) {
        var qb = QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.addInt("limit", params.limit);
        try qb.addInt("offset", params.offset);
        try qb.addArrayParam("translatedLanguage", params.translatedLanguage);
        try qb.addArrayParam("originalLanguage", params.originalLanguage);
        try qb.addArrayParam("excludedOriginalLanguage", params.excludedOriginalLanguage);
        try qb.addArrayParam("contentRating", params.contentRating);
        try qb.addArrayParam("includes", params.includes);
        if (params.order_chapter) |ord| {
            try qb.addParam("order[chapter]", ord);
        }

        const base_url = try std.fmt.allocPrint(self.allocator, "{s}/manga/{s}/feed", .{ self.config.api_url, manga_id });
        defer self.allocator.free(base_url);

        const full_url = try qb.buildUrl(base_url);
        defer self.allocator.free(full_url);

        const res = try self.sendRequest(.GET, full_url, null, "");
        const parsed = std.json.parseFromSlice(
            PagedResponse(Chapter),
            self.allocator,
            res.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.JsonParseError;

        return .{
            .parsed = parsed,
            .items = parsed.value.data,
            .total = parsed.value.total,
            .limit = parsed.value.limit,
            .offset = parsed.value.offset,
        };
    }

    pub fn getMangaAggregate(self: *MangaDexClient, manga_id: []const u8, langs: []const []const u8) ClientError!std.json.Parsed(AggregateResponse) {
        var qb = QueryBuilder.init(self.allocator);
        defer qb.deinit();
        try qb.addArrayParam("translatedLanguage", langs);

        const base_url = try std.fmt.allocPrint(self.allocator, "{s}/manga/{s}/aggregate", .{ self.config.api_url, manga_id });
        defer self.allocator.free(base_url);

        const full_url = try qb.buildUrl(base_url);
        defer self.allocator.free(full_url);

        const res = try self.sendRequest(.GET, full_url, null, "");
        return std.json.parseFromSlice(
            AggregateResponse,
            self.allocator,
            res.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.JsonParseError;
    }

    pub fn getChapter(self: *MangaDexClient, chapter_id: []const u8, includes: []const []const u8) ClientError!EntityResult(Chapter) {
        var qb = QueryBuilder.init(self.allocator);
        defer qb.deinit();
        try qb.addArrayParam("includes", includes);

        const base_url = try std.fmt.allocPrint(self.allocator, "{s}/chapter/{s}", .{ self.config.api_url, chapter_id });
        defer self.allocator.free(base_url);

        const full_url = try qb.buildUrl(base_url);
        defer self.allocator.free(full_url);

        const res = try self.sendRequest(.GET, full_url, null, "");
        const parsed = std.json.parseFromSlice(
            EntityResponse(Chapter),
            self.allocator,
            res.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.JsonParseError;

        return .{
            .parsed = parsed,
            .data = parsed.value.data,
        };
    }

    pub fn getAtHomeServer(self: *MangaDexClient, chapter_id: []const u8, force_port_443: bool) ClientError!AtHomeResult {
        const base_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/at-home/server/{s}?forcePort443={s}",
            .{ self.config.api_url, chapter_id, if (force_port_443) "true" else "false" },
        );
        defer self.allocator.free(base_url);

        const res = try self.sendRequest(.GET, base_url, null, "");
        const parsed = std.json.parseFromSlice(
            AtHomeServerResponse,
            self.allocator,
            res.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.JsonParseError;

        return .{
            .parsed = parsed,
            .baseUrl = parsed.value.baseUrl,
            .chapter = parsed.value.chapter,
        };
    }

    pub fn getCover(self: *MangaDexClient, cover_id: []const u8) ClientError!EntityResult(Cover) {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/cover/{s}", .{ self.config.api_url, cover_id });
        defer self.allocator.free(url);

        const res = try self.sendRequest(.GET, url, null, "");
        const parsed = std.json.parseFromSlice(
            EntityResponse(Cover),
            self.allocator,
            res.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.JsonParseError;

        return .{
            .parsed = parsed,
            .data = parsed.value.data,
        };
    }

    pub fn getUserFollowedMangaFeed(self: *MangaDexClient, params: MangaFeedParams, now_ms: u64) ClientError!PagedResult(Chapter) {
        var auth_header: ?[]const u8 = null;
        if (self.auth) |a| {
            auth_header = a.getAuthorizationHeader(self.transport, now_ms) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unauthorized,
            };
        }

        var qb = QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.addInt("limit", params.limit);
        try qb.addInt("offset", params.offset);
        try qb.addArrayParam("translatedLanguage", params.translatedLanguage);
        try qb.addArrayParam("contentRating", params.contentRating);
        try qb.addArrayParam("includes", params.includes);
        if (params.order_chapter) |ord| {
            try qb.addParam("order[chapter]", ord);
        }

        const base_url = try std.fmt.allocPrint(self.allocator, "{s}/user/follows/manga/feed", .{self.config.api_url});
        defer self.allocator.free(base_url);

        const full_url = try qb.buildUrl(base_url);
        defer self.allocator.free(full_url);

        const res = try self.sendRequest(.GET, full_url, auth_header, "");
        const parsed = std.json.parseFromSlice(
            PagedResponse(Chapter),
            self.allocator,
            res.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.JsonParseError;

        return .{
            .parsed = parsed,
            .items = parsed.value.data,
            .total = parsed.value.total,
            .limit = parsed.value.limit,
            .offset = parsed.value.offset,
        };
    }

    pub fn markChapterRead(
        self: *MangaDexClient,
        manga_id: []const u8,
        read_ids: []const []const u8,
        unread_ids: []const []const u8,
        now_ms: u64,
    ) ClientError!void {
        var auth_header: ?[]const u8 = null;
        if (self.auth) |a| {
            auth_header = a.getAuthorizationHeader(self.transport, now_ms) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unauthorized,
            };
        }

        const url = try std.fmt.allocPrint(self.allocator, "{s}/manga/{s}/read", .{ self.config.api_url, manga_id });
        defer self.allocator.free(url);

        const MarkerPayload = struct {
            chapterIdsRead: []const []const u8,
            chapterIdsUnread: []const []const u8,
        };

        const payload = MarkerPayload{
            .chapterIdsRead = read_ids,
            .chapterIdsUnread = unread_ids,
        };

        var string_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer string_buf.deinit(self.allocator);
        try std.json.stringify(payload, .{}, string_buf.writer(self.allocator));

        _ = try self.sendRequest(.POST, url, auth_header, string_buf.items);
    }

    fn sendRequest(
        self: *MangaDexClient,
        method: HttpMethod,
        url: []const u8,
        auth_header: ?[]const u8,
        body: []const u8,
    ) ClientError!http.HttpResponse {
        var headers: std.ArrayListUnmanaged(HttpHeader) = .empty;
        defer headers.deinit(self.allocator);

        try headers.append(self.allocator, .{ .name = "Accept", .value = "application/json" });
        try headers.append(self.allocator, .{ .name = "User-Agent", .value = self.config.user_agent });

        if (body.len > 0) {
            try headers.append(self.allocator, .{ .name = "Content-Type", .value = "application/json" });
        }

        if (auth_header) |hdr| {
            try headers.append(self.allocator, .{ .name = "Authorization", .value = hdr });
        }

        const res = self.transport.execute(
            self.allocator,
            method,
            url,
            headers.items,
            body,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Timeout => error.Timeout,
            error.RateLimited => error.RateLimited,
            error.InvalidUrl => error.InvalidUrl,
            error.NetworkFailure => error.NetworkFailure,
        };

        if (res.status_code == 404) return error.NotFound;
        if (res.status_code == 401 or res.status_code == 403) return error.Unauthorized;
        if (res.status_code == 429) return error.RateLimited;
        if (res.status_code >= 400) return error.HttpError;

        return res;
    }
};
