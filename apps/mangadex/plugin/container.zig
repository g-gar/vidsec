const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const abi = flowdata.plugin;
const sdk = @import("mangadex_sdk");
const sources = @import("sources");
const adapters = @import("mangadex_app").adapters;
const AppConfig = @import("mangadex_app").config.AppConfig;

const TaskContext = abi.TaskContext;
const MangaDexClient = sdk.MangaDexClient;
const MangaSource = sources.MangaSource;
const MangaDexSource = sources.MangaDexSource;
const HtmlGenericSource = sources.HtmlGenericSource;
const FlowdataHttpAdapter = adapters.FlowdataHttpAdapter;

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

pub const MangaContext = struct {
    http: FlowdataHttpAdapter,
    mangadex_client: MangaDexClient,
    mangadex_driver: MangaDexSource,
    html_generic_driver: HtmlGenericSource,

    pub fn init(self: *MangaContext, alloc: Allocator, ctx: TaskContext) !void {
        self.http = FlowdataHttpAdapter.fromTaskContext(ctx);
        self.mangadex_client = createClient(alloc, ctx, &self.http);
        self.mangadex_driver = MangaDexSource.init(&self.mangadex_client);
        self.html_generic_driver = HtmlGenericSource.init("html_generic", "https://visortmo.com");
    }

    pub fn deinit(_: *MangaContext) void {}

    /// @Bean Factory Method: Automatically discovered at comptime by Flowdata's DI engine
    /// whenever a Service declares a field `source: MangaSource`.
    pub fn provideMangaSource(self: *MangaContext, input: anytype) !MangaSource {
        const candidates = [_]MangaSource{
            self.mangadex_driver.mangaSource(),
            self.html_generic_driver.mangaSource(),
        };

        const InType = @TypeOf(input);

        // 1. Explicit datasource override in input DTO
        if (@typeInfo(InType) == .@"struct" and @hasField(InType, "datasource")) {
            if (input.datasource) |req_id| {
                if (req_id.len > 0) {
                    for (candidates) |src| {
                        if (std.mem.eql(u8, src.getSourceId(), req_id)) return src;
                    }
                    return error.SourceNotFound;
                }
            }
        }

        // 2. Dynamic capability matching via canHandle (UUID v4 vs. URL pattern)
        const target_id: []const u8 = if (@typeInfo(InType) == .@"struct") blk: {
            if (@hasField(InType, "series_id")) {
                const sid = input.series_id;
                if (@TypeOf(sid) == []const u8) {
                    if (sid.len > 0) break :blk sid;
                } else if (@TypeOf(sid) == ?[]const u8) {
                    if (sid) |s| {
                        if (s.len > 0) break :blk s;
                    }
                }
            }
            if (@hasField(InType, "source_chapter_id")) {
                const cid = input.source_chapter_id;
                if (@TypeOf(cid) == []const u8) {
                    if (cid.len > 0) break :blk cid;
                } else if (@TypeOf(cid) == ?[]const u8) {
                    if (cid) |c| {
                        if (c.len > 0) break :blk c;
                    }
                }
            }
            break :blk "";
        } else "";

        if (target_id.len > 0) {
            for (candidates) |src| {
                if (src.canHandle(target_id)) return src;
            }
        }

        // 3. Default provider fallback
        return candidates[0];
    }
};

/// Application DI Container (inherits defineTaskService, inject, and runWithContext from abi.DiContainer)
pub const MangaPluginContainer = abi.DiContainer(MangaContext);
