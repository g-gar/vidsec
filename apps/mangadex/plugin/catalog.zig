const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const abi = flowdata.plugin;
const sdk = @import("mangadex_sdk");
const sources = @import("sources");
const adapters = @import("mangadex_app").adapters;

const TaskContext = abi.TaskContext;
const MangaDexClient = sdk.MangaDexClient;
const MangaDexSource = sources.MangaDexSource;
const FlowdataHttpAdapter = adapters.FlowdataHttpAdapter;
const AppConfig = @import("mangadex_app").config.AppConfig;

fn createClient(alloc: Allocator, ctx: TaskContext, http_bridge: *FlowdataHttpAdapter) MangaDexClient {
    var app_cfg = AppConfig.load(alloc, "configs/.env") catch AppConfig.load(alloc, ".env") catch AppConfig{};
    var interp = flowdata.yaml.EnvInterpolator.init(true);
    defer interp.deinit(alloc);
    if (AppConfig.readDotEnvFile(alloc, "configs/.env")) |dotenv| {
        defer alloc.free(dotenv);
        interp.parseDotEnv(alloc, dotenv) catch {};
    } else if (AppConfig.readDotEnvFile(alloc, ".env")) |dotenv| {
        defer alloc.free(dotenv);
        interp.parseDotEnv(alloc, dotenv) catch {};
    }

    // 1. Resolve User-Agent: task param in pipeline.yaml > .env / env var > fallback
    var user_agent = app_cfg.user_agent;
    if (ctx.getParam("user_agent") catch null) |ua_val| {
        if (ua_val.asText()) |ua| {
            if (ua.len > 0) user_agent = ua;
        }
    }

    // 2. Resolve Auth Provider: task param in pipeline.yaml > .env / env vars > anonymous
    var auth_provider: ?sdk.AuthProvider = null;
    if (ctx.getParam("token") catch null) |tok_val| {
        if (tok_val.asText()) |t| {
            if (t.len > 0) auth_provider = sdk.StaticTokenAuth.create(alloc, t) catch null;
        }
    }
    if (auth_provider == null) {
        auth_provider = app_cfg.resolveAuthProvider(alloc, &interp) catch null;
    }

    // 3. Resolve API URL: task param in pipeline.yaml > .env / env var > default
    var api_url = app_cfg.api_url;
    if (ctx.getParam("api_url") catch null) |url_val| {
        if (url_val.asText()) |u| {
            if (u.len > 0) api_url = u;
        }
    }

    return MangaDexClient.init(
        alloc,
        .{
            .api_url = api_url,
            .user_agent = user_agent,
        },
        http_bridge.httpTransport(),
        auth_provider,
    );
}

// =============================================================================
// Output Structs (Return Types)
// =============================================================================

pub const SeriesDetails = struct {
    series_id: []const u8,
    title: []const u8,
    author: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    status: []const u8,
    year: ?i64 = null,
    cover_url: ?[]const u8 = null,
    available_languages: []const u8 = "",
    summary: ?[]const u8 = null,
};

pub const ChapterItem = struct {
    source_chapter_id: []const u8,
    series_id: []const u8,
    chapter_number: []const u8,
    volume_number: ?[]const u8 = null,
    title: ?[]const u8 = null,
    language: []const u8,
    scanlation_group: ?[]const u8 = null,
};

pub const ChapterPageItem = struct {
    source_chapter_id: []const u8,
    page_number: u32,
    url: []const u8,
};

// =============================================================================
// 1. Task: fetch_series_details
// Consumes job / subscription specification dynamically: job.series_id, job.languages, etc.
// =============================================================================

pub const MangaJob = struct {
    series_id: []const u8,
    datasource: ?[]const u8 = null,
    languages: []const u8 = "en",
    chapters: []const u8 = "all",
};

pub fn runFetchSeriesDetails(alloc: Allocator, ctx: TaskContext, job: MangaJob) !SeriesDetails {
    var http_bridge = FlowdataHttpAdapter.fromTaskContext(ctx);
    var client = createClient(alloc, ctx, &http_bridge);

    var source = MangaDexSource.init(&client);
    const m_source = source.mangaSource();

    ctx.logInfoFmt("Fetching series details for series_id={s}", .{job.series_id});
    const details = try m_source.getDetails(alloc, job.series_id);

    var langs_buf: std.ArrayListUnmanaged(u8) = .empty;
    for (details.available_languages, 0..) |lang, idx| {
        if (idx > 0) try langs_buf.append(alloc, ',');
        try langs_buf.appendSlice(alloc, lang);
    }

    return SeriesDetails{
        .series_id = job.series_id,
        .title = details.title,
        .author = details.author,
        .artist = details.artist,
        .status = details.status,
        .year = if (details.year) |y| @intCast(y) else null,
        .cover_url = details.cover_url,
        .available_languages = langs_buf.items,
        .summary = details.summary,
    };
}

// =============================================================================
// 2. Task: fetch_chapters
// =============================================================================

pub const FetchChaptersInputs = struct {
    series_id: []const u8,
    languages: []const u8 = "en",
    datasource: ?[]const u8 = null,
};

pub fn runFetchChapters(alloc: Allocator, ctx: TaskContext, inputs: FetchChaptersInputs) ![]ChapterItem {
    var http_bridge = FlowdataHttpAdapter.fromTaskContext(ctx);
    var client = createClient(alloc, ctx, &http_bridge);

    var source = MangaDexSource.init(&client);
    const m_source = source.mangaSource();

    var chapters_list: std.ArrayListUnmanaged(ChapterItem) = .empty;

    var lang_iter = std.mem.tokenizeScalar(u8, inputs.languages, ',');
    while (lang_iter.next()) |raw_lang| {
        const lang = std.mem.trim(u8, raw_lang, " \t\r\n");
        if (lang.len == 0) continue;

        ctx.logInfoFmt("Fetching chapters for series '{s}' in language '{s}'", .{ inputs.series_id, lang });
        const chapters = try m_source.getChapters(alloc, inputs.series_id, lang);
        for (chapters) |ch| {
            try chapters_list.append(alloc, .{
                .source_chapter_id = ch.source_chapter_id,
                .series_id = inputs.series_id,
                .chapter_number = ch.chapter_number,
                .volume_number = ch.volume_number,
                .title = ch.title,
                .language = ch.language_iso,
                .scanlation_group = ch.scanlation_group,
            });
        }
    }

    ctx.logInfoFmt("Total chapters discovered for series '{s}': {d}", .{ inputs.series_id, chapters_list.items.len });
    return chapters_list.toOwnedSlice(alloc);
}

// =============================================================================
// 3. Task: fetch_chapter_pages
// =============================================================================

pub const FetchChapterPagesInputs = struct {
    source_chapter_id: []const u8,
    chapter_number: ?[]const u8 = null,
    series_id: ?[]const u8 = null,
};

pub fn runFetchChapterPages(alloc: Allocator, ctx: TaskContext, inputs: FetchChapterPagesInputs) ![]ChapterPageItem {
    var http_bridge = FlowdataHttpAdapter.fromTaskContext(ctx);
    var client = createClient(alloc, ctx, &http_bridge);

    var source = MangaDexSource.init(&client);
    const m_source = source.mangaSource();

    ctx.logInfoFmt("Fetching pages for chapter '{s}' (chapter_number: {s})", .{
        inputs.source_chapter_id,
        inputs.chapter_number orelse "?",
    });

    const pages = try m_source.getPageUrls(alloc, inputs.source_chapter_id);

    var page_list = try alloc.alloc(ChapterPageItem, pages.len);
    for (pages, 0..) |p, idx| {
        page_list[idx] = .{
            .source_chapter_id = inputs.source_chapter_id,
            .page_number = p.page_number,
            .url = p.url,
        };
    }

    ctx.logInfoFmt("Total pages discovered for chapter '{s}': {d}", .{ inputs.source_chapter_id, page_list.len });
    return page_list;
}

// =============================================================================
// 4. Module Manifest & C-ABI Exports
// =============================================================================

pub const tasks = [_]abi.TaskDescriptor_ABI{
    abi.defineTask(.{
        .name = "fetch_series_details",
        .description = "Retrieves series metadata (title, author, artist, cover URL, available languages) from configured MangaSource",
        .run = &runFetchSeriesDetails,
    }),
    abi.defineTask(.{
        .name = "fetch_chapters",
        .description = "Retrieves chapters list for series in the specified language(s) from configured MangaSource",
        .run = &runFetchChapters,
    }),
    abi.defineTask(.{
        .name = "fetch_chapter_pages",
        .description = "Retrieves page URLs and metadata for a specific chapter from configured MangaSource",
        .run = &runFetchChapterPages,
    }),
};

pub const manifest: abi.ModuleManifest_ABI = abi.defineManifest(
    "manga_catalog",
    .{ .major = 1, .minor = 0, .patch = 0 },
    &tasks,
);

comptime {
    if (@import("root") == @This()) {
        @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
    }
}
