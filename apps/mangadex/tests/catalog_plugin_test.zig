const std = @import("std");
const flowdata = @import("flowdata");
const abi = flowdata.plugin;
const plugin = @import("mangadex_plugin");
const catalog = plugin.catalog;
const sdk = @import("mangadex_sdk");

test "Catalog plugin manifest conforms to Flowdata ABI" {
    const manifest = catalog.manifest;

    try std.testing.expectEqual(abi.FLOWDATA_ABI_VERSION, manifest.abi_version);
    try std.testing.expectEqualStrings("manga_catalog", manifest.nameSlice());
    try std.testing.expectEqual(@as(u32, 1), manifest.module_version.major);
    try std.testing.expectEqual(@as(usize, 10), manifest.tasks_len);

    // Verify task discovery
    const t_details = manifest.findTask("fetch_series_details");
    try std.testing.expect(t_details != null);
    try std.testing.expectEqualStrings("fetch_series_details", t_details.?.nameSlice());
    try std.testing.expect(t_details.?.declaresOutputField("series_id"));
    try std.testing.expect(t_details.?.declaresOutputField("title"));
    try std.testing.expect(t_details.?.declaresOutputField("available_languages"));
    try std.testing.expect(t_details.?.declaresOutputField("cover_url"));

    const t_chapters = manifest.findTask("fetch_chapters");
    try std.testing.expect(t_chapters != null);
    try std.testing.expectEqualStrings("fetch_chapters", t_chapters.?.nameSlice());
    try std.testing.expect(t_chapters.?.declaresOutputField("source_chapter_id"));
    try std.testing.expect(t_chapters.?.declaresOutputField("chapter_number"));
    try std.testing.expect(t_chapters.?.declaresOutputField("language"));

    const t_pages = manifest.findTask("fetch_chapter_pages");
    try std.testing.expect(t_pages != null);
    try std.testing.expectEqualStrings("fetch_chapter_pages", t_pages.?.nameSlice());
    try std.testing.expect(t_pages.?.declaresOutputField("source_chapter_id"));
    try std.testing.expect(t_pages.?.declaresOutputField("page_number"));
    try std.testing.expect(t_pages.?.declaresOutputField("url"));

    try std.testing.expect(manifest.findTask("download_chapter_page") != null);
    try std.testing.expect(manifest.findTask("detect_content_type") != null);
    try std.testing.expect(manifest.findTask("analyze_image") != null);
    try std.testing.expect(manifest.findTask("generate_comicinfo") != null);
    try std.testing.expect(manifest.findTask("build_cbz_archive") != null);
    try std.testing.expect(manifest.findTask("upload_cbz") != null);
}

// Mock TaskContext for execution testing
const MockPluginHost = struct {
    allocator: std.mem.Allocator,
    series_id_param: []const u8 = "series-test-uuid",
    languages_param: []const u8 = "es,en",
    emitted_rows: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) MockPluginHost {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MockPluginHost) void {
        for (self.emitted_rows.items) |r| self.allocator.free(r);
        self.emitted_rows.deinit(self.allocator);
    }

    pub fn taskContext(self: *MockPluginHost) abi.TaskContext {
        const Trampoline = struct {
            fn getParam(ctx: *abi.TaskContext_ABI, key_ptr: [*:0]const u8, out_val: *abi.Value_ABI) callconv(.c) abi.HostError_ABI {
                const host: *MockPluginHost = @ptrCast(@alignCast(ctx.opaque_host_state));
                const key = std.mem.span(key_ptr);
                if (std.mem.eql(u8, key, "series_id")) {
                    out_val.* = abi.Value_ABI.fromText(host.series_id_param);
                    return .ok;
                } else if (std.mem.eql(u8, key, "languages")) {
                    out_val.* = abi.Value_ABI.fromText(host.languages_param);
                    return .ok;
                }
                return .not_found;
            }

            fn emitRow(ctx: *abi.TaskContext_ABI, channel_ptr: ?[*:0]const u8, fields_ptr: [*]const abi.NamedField_ABI, fields_len: usize) callconv(.c) abi.HostError_ABI {
                const host: *MockPluginHost = @ptrCast(@alignCast(ctx.opaque_host_state));
                const channel = if (channel_ptr) |cp| std.mem.span(cp) else "default";
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                buf.appendSlice(host.allocator, channel) catch return .out_of_memory;
                buf.appendSlice(host.allocator, ":") catch return .out_of_memory;
                for (fields_ptr[0..fields_len]) |f| {
                    buf.appendSlice(host.allocator, f.nameSlice()) catch return .out_of_memory;
                    buf.appendSlice(host.allocator, "=") catch return .out_of_memory;
                    if (f.value.asText()) |txt| {
                        buf.appendSlice(host.allocator, txt) catch return .out_of_memory;
                    }
                    buf.appendSlice(host.allocator, ";") catch return .out_of_memory;
                }
                const owned = buf.toOwnedSlice(host.allocator) catch return .out_of_memory;
                host.emitted_rows.append(host.allocator, owned) catch return .out_of_memory;
                return .ok;
            }

            fn netRequest(_: *abi.TaskContext_ABI, req: *const abi.NetRequest_ABI, out_resp: *abi.NetResponse_ABI) callconv(.c) abi.HostError_ABI {
                const url = req.url.toSlice();
                if (std.mem.indexOf(u8, url, "/manga/series-test-uuid") != null and std.mem.indexOf(u8, url, "/feed") == null) {
                    const json =
                        \\{"result":"ok","response":"entity","data":{"id":"series-test-uuid","type":"manga","attributes":{"title":{"en":"Chainsaw Man"},"altTitles":[{"ja":"チェンソーマン"}],"description":{"en":"Denji has a simple dream"},"status":"ongoing","year":2018,"availableTranslatedLanguages":["en","es","fr"]},"relationships":[{"id":"auth-1","type":"author","attributes":{"name":"Tatsuki Fujimoto"}},{"id":"cov-1","type":"cover_art","attributes":{"fileName":"c1.jpg"}}]}}
                    ;
                    out_resp.* = .{
                        .status_code = 200,
                        .body = abi.Slice_ABI.fromSlice(json),
                    };
                    return .ok;
                } else if (std.mem.indexOf(u8, url, "/feed") != null) {
                    const json =
                        \\{"result":"ok","response":"collection","data":[{"id":"ch-es-1","type":"chapter","attributes":{"volume":"1","chapter":"1","title":"Perro y Motosierra","translatedLanguage":"es"},"relationships":[{"id":"grp-1","type":"scanlation_group","attributes":{"name":"FansubES"}}]}],"limit":100,"offset":0,"total":1}
                    ;
                    out_resp.* = .{
                        .status_code = 200,
                        .body = abi.Slice_ABI.fromSlice(json),
                    };
                    return .ok;
                }
                return .not_found;
            }

            fn logEvent(_: *abi.TaskContext_ABI, _: abi.LogLevel_ABI, _: [*]const u8, _: usize) callconv(.c) void {}
            fn streamSize(_: *abi.TaskContext_ABI) callconv(.c) u64 {
                return 0;
            }
            fn streamReadAt(_: *abi.TaskContext_ABI, _: u64, _: [*]u8, _: usize) callconv(.c) abi.HostError_ABI {
                return .ok;
            }
            fn nextWindow(_: *abi.TaskContext_ABI, _: ?[*:0]const u8, _: *abi.WindowView_ABI) callconv(.c) abi.HostError_ABI {
                return .end_of_stream;
            }
            fn windowReadAt(_: *abi.TaskContext_ABI, _: *const abi.WindowView_ABI, _: u64, _: [*]u8, _: usize) callconv(.c) abi.HostError_ABI {
                return .ok;
            }
            fn nextRow(_: *abi.TaskContext_ABI, _: [*:0]const u8, _: *abi.RowView_ABI) callconv(.c) abi.HostError_ABI {
                return .end_of_stream;
            }
            fn artifactWriteAt(_: *abi.TaskContext_ABI, _: u64, _: [*]const u8, _: usize) callconv(.c) abi.HostError_ABI {
                return .ok;
            }
            fn artifactZeroRange(_: *abi.TaskContext_ABI, _: u64, _: u64) callconv(.c) abi.HostError_ABI {
                return .ok;
            }
            fn artifactTruncate(_: *abi.TaskContext_ABI, _: u64) callconv(.c) abi.HostError_ABI {
                return .ok;
            }
            fn carveToQuarantine(_: *abi.TaskContext_ABI, _: u64, _: u64, _: [*:0]const u8, _: *[64]u8) callconv(.c) abi.HostError_ABI {
                return .ok;
            }
            const vtable = abi.HostApiVTable_ABI{
                .stream_size = &streamSize,
                .stream_read_at = &streamReadAt,
                .next_window = &nextWindow,
                .window_read_at = &windowReadAt,
                .next_row = &nextRow,
                .get_param = &getParam,
                .emit_row = &emitRow,
                .artifact_write_at = &artifactWriteAt,
                .artifact_zero_range = &artifactZeroRange,
                .artifact_truncate = &artifactTruncate,
                .carve_to_quarantine = &carveToQuarantine,
                .log_event = &logEvent,
                .net_request = &netRequest,
            };
        };

        const raw = self.allocator.create(abi.TaskContext_ABI) catch unreachable;
        raw.* = .{
            .abi_version = abi.FLOWDATA_ABI_VERSION,
            .opaque_host_state = self,
            .host = &Trampoline.vtable,
        };
        return abi.TaskContext.init(raw);
    }
};

test "Catalog tasks return typed structs and C-ABI trampoline auto-emits outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    var host = MockPluginHost.init(test_alloc);
    defer host.deinit();

    const ctx = host.taskContext();

    // 1. Direct call returns SeriesDetails struct without manual emits
    const details = try catalog.runFetchSeriesDetails(test_alloc, ctx, .{
        .series_id = "series-test-uuid",
    });
    try std.testing.expectEqualStrings("series-test-uuid", details.series_id);
    try std.testing.expectEqualStrings("Chainsaw Man", details.title);
    try std.testing.expectEqualStrings("Tatsuki Fujimoto", details.author.?);
    try std.testing.expectEqualStrings("en,es,fr", details.available_languages);

    // 2. Direct call returns []ChapterItem slice without manual emits
    const chapters = try catalog.runFetchChapters(test_alloc, ctx, .{
        .series_id = "series-test-uuid",
        .languages = "es",
    });
    try std.testing.expectEqual(@as(usize, 1), chapters.len);
    try std.testing.expectEqualStrings("ch-es-1", chapters[0].source_chapter_id);
    try std.testing.expectEqualStrings("1", chapters[0].chapter_number);
    try std.testing.expectEqualStrings("Perro y Motosierra", chapters[0].title.?);
    try std.testing.expectEqualStrings("es", chapters[0].language);

    // 3. Test C-ABI Trampoline execution: injects inputs and auto-emits typed rows
    const manifest = catalog.manifest;
    const t_details = manifest.findTask("fetch_series_details").?;
    const status1 = t_details.execute(ctx.raw);
    try std.testing.expectEqual(abi.TaskStatus_ABI.ok, status1);
    try std.testing.expect(host.emitted_rows.items.len >= 1);
    const row1 = host.emitted_rows.items[0];
    try std.testing.expect(std.mem.indexOf(u8, row1, "title=Chainsaw Man;") != null);

    const t_chapters = manifest.findTask("fetch_chapters").?;
    const status2 = t_chapters.execute(ctx.raw);
    try std.testing.expectEqual(abi.TaskStatus_ABI.ok, status2);
    try std.testing.expect(host.emitted_rows.items.len >= 2);
    const row2 = host.emitted_rows.items[1];
    try std.testing.expect(std.mem.indexOf(u8, row2, "source_chapter_id=ch-es-1;") != null);
}

test "Catalog dynamic datasource resolution and unknown source error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    var host = MockPluginHost.init(test_alloc);
    defer host.deinit();
    const ctx = host.taskContext();

    // 1. Explicit 'mangadex' datasource resolves properly
    const details = try catalog.runFetchSeriesDetails(test_alloc, ctx, .{
        .series_id = "series-test-uuid",
        .datasource = "mangadex",
    });
    try std.testing.expectEqualStrings("Chainsaw Man", details.title);

    // 2. Unknown datasource returns error.SourceNotFound
    const bad_res = catalog.runFetchSeriesDetails(test_alloc, ctx, .{
        .series_id = "series-test-uuid",
        .datasource = "non_existent_provider",
    });
    try std.testing.expectError(error.SourceNotFound, bad_res);

    // 3. Generic HTML placeholder returns error.NotImplemented
    const placeholder_res = catalog.runFetchSeriesDetails(test_alloc, ctx, .{
        .series_id = "series-test-uuid",
        .datasource = "html_generic",
    });
    try std.testing.expectError(error.NotImplemented, placeholder_res);

    // 4. Auto-detection when datasource is omitted: generic URL resolves html_generic
    const auto_html = catalog.runFetchSeriesDetails(test_alloc, ctx, .{
        .series_id = "https://visortmo.com/library/manga/123/kingdom",
        .datasource = null,
    });
    try std.testing.expectError(error.NotImplemented, auto_html);

    // 5. Auto-detection when datasource is omitted: UUID or fallback resolves mangadex
    const auto_md = try catalog.runFetchSeriesDetails(test_alloc, ctx, .{
        .series_id = "series-test-uuid",
        .datasource = null,
    });
    try std.testing.expectEqualStrings("Chainsaw Man", auto_md.title);
}

const sources = @import("sources");
const MangaSource = sources.MangaSource;
const SourceMangaSummary = sources.SourceMangaSummary;
const SourceSeriesDetails = sources.SourceSeriesDetails;
const SourceChapter = sources.SourceChapter;
const SourcePageUrl = sources.SourcePageUrl;

const MockMangaSource = struct {
    pub fn mangaSource(self: *MockMangaSource) MangaSource {
        return .{
            .ptr = self,
            .vtable = &.{
                .getSourceId = getSourceId,
                .search = search,
                .getDetails = getDetails,
                .getChapters = getChapters,
                .getPageUrls = getPageUrls,
                .canHandle = canHandle,
            },
        };
    }

    fn getSourceId(_: *anyopaque) []const u8 {
        return "mock_manga_source";
    }

    fn search(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]SourceMangaSummary {
        return &.{};
    }

    fn getDetails(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!SourceSeriesDetails {
        return SourceSeriesDetails{
            .title = "Mock Chainsaw Man",
            .author = "Mock Author",
            .artist = "Mock Artist",
            .status = "ongoing",
            .available_languages = &[_][]const u8{ "en", "es" },
        };
    }

    fn getChapters(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror![]SourceChapter {
        return &.{};
    }

    fn getPageUrls(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]SourcePageUrl {
        return &.{};
    }

    fn canHandle(_: *anyopaque, _: []const u8) bool {
        return true;
    }
};

test "FetchSeriesDetailsService: direct struct instantiation (pure unit test)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    var mock = MockMangaSource{};
    var service = catalog.FetchSeriesDetailsService{
        .source = mock.mangaSource(),
        .logger = abi.Logger.noop(),
    };

    const details = try service.execute(test_alloc, .{
        .series_id = "mock-uuid-123",
    });
    try std.testing.expectEqualStrings("mock-uuid-123", details.series_id);
    try std.testing.expectEqualStrings("Mock Chainsaw Man", details.title);
    try std.testing.expectEqualStrings("Mock Author", details.author.?);
    try std.testing.expectEqualStrings("en,es", details.available_languages);
}

test "FetchSeriesDetailsService: DI injection via TestContainer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    const TestContext = struct {
        mock_source: MockMangaSource = .{},
        logger: abi.Logger = abi.Logger.noop(),

        pub fn provideMangaSource(self: *@This(), _: anytype) MangaSource {
            return self.mock_source.mangaSource();
        }
    };
    const TestContainer = abi.DiContainer(TestContext);

    var test_ctx = TestContext{};
    const job = catalog.MangaJob{ .series_id = "test-di-series" };

    var service = try TestContainer.inject(
        catalog.FetchSeriesDetailsService,
        &test_ctx,
        test_alloc,
        job,
    );

    const details = try service.execute(test_alloc, job);
    try std.testing.expectEqualStrings("test-di-series", details.series_id);
    try std.testing.expectEqualStrings("Mock Chainsaw Man", details.title);
}

// ---------------------------------------------------------------------------
// Tests for DownloadChapterPageService
// ---------------------------------------------------------------------------

const MockPageHttpTransport = struct {
    status_code: u16 = 200,
    response_body: []const u8 = "\x89PNG\r\n\x1a\nfake-png-binary-stream",

    pub fn httpTransport(self: *MockPageHttpTransport) sdk.HttpTransport {
        return .{
            .ptr = self,
            .vtable = &.{ .execute = executeMock },
        };
    }

    fn executeMock(
        ctx: *anyopaque,
        _: std.mem.Allocator,
        _: sdk.HttpMethod,
        _: []const u8,
        _: []const sdk.HttpHeader,
        _: []const u8,
    ) sdk.HttpTransportError!sdk.HttpResponse {
        const self: *MockPageHttpTransport = @ptrCast(@alignCast(ctx));
        if (self.status_code == 0) return error.NetworkFailure;
        return .{
            .status_code = self.status_code,
            .body = self.response_body,
        };
    }
};

test "DownloadChapterPageService: direct execution downloads raw bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    var mock_http = MockPageHttpTransport{
        .response_body = "\x89PNG\r\n\x1a\nraw-png-bytes",
    };

    var service = catalog.DownloadChapterPageService{
        .http = mock_http.httpTransport(),
        .logger = abi.Logger.noop(),
    };

    const item = catalog.ChapterPageItem{
        .source_chapter_id = "chap-123",
        .page_number = 1,
        .url = "https://cdn.mangadex.org/data/hash/1-png.png",
    };

    const downloaded = try service.execute(test_alloc, item);
    try std.testing.expectEqualStrings("chap-123", downloaded.source_chapter_id);
    try std.testing.expectEqual(@as(u32, 1), downloaded.page_number);
    try std.testing.expectEqualStrings("https://cdn.mangadex.org/data/hash/1-png.png", downloaded.url);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\nraw-png-bytes", downloaded.image_data);
}

test "DownloadChapterPageService: error on HTTP 404 or empty URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    var mock_http = MockPageHttpTransport{
        .status_code = 404,
    };

    var service = catalog.DownloadChapterPageService{
        .http = mock_http.httpTransport(),
        .logger = abi.Logger.noop(),
    };

    const item = catalog.ChapterPageItem{
        .source_chapter_id = "chap-123",
        .page_number = 1,
        .url = "https://cdn.mangadex.org/data/missing.jpg",
    };

    try std.testing.expectError(error.HttpDownloadFailed, service.execute(test_alloc, item));

    // Empty URL error
    const empty_item = catalog.ChapterPageItem{
        .source_chapter_id = "chap-123",
        .page_number = 1,
        .url = "",
    };
    try std.testing.expectError(error.EmptyPageUrl, service.execute(test_alloc, empty_item));
}

test "DownloadChapterPageService: DI injection via TestContainer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    const TestContext = struct {
        mock_http: MockPageHttpTransport = .{},
        logger: abi.Logger = abi.Logger.noop(),

        pub fn provideHttpTransport(self: *@This()) sdk.HttpTransport {
            return self.mock_http.httpTransport();
        }
    };
    const TestContainer = abi.DiContainer(TestContext);

    var test_ctx = TestContext{};
    const item = catalog.ChapterPageItem{
        .source_chapter_id = "chap-di",
        .page_number = 5,
        .url = "https://example.com/page5.png",
    };

    var service = try TestContainer.inject(
        catalog.DownloadChapterPageService,
        &test_ctx,
        test_alloc,
        item,
    );

    const downloaded = try service.execute(test_alloc, item);
    try std.testing.expectEqualStrings("chap-di", downloaded.source_chapter_id);
    try std.testing.expectEqual(@as(u32, 5), downloaded.page_number);
    try std.testing.expectEqualStrings("https://example.com/page5.png", downloaded.url);
}

// ---------------------------------------------------------------------------
// Tests for DetectContentTypeService
// ---------------------------------------------------------------------------

test "DetectContentTypeService: detect magic bytes for PNG, JPEG, WebP, GIF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    var service = catalog.DetectContentTypeService{
        .logger = abi.Logger.noop(),
    };

    // PNG
    const png_item = catalog.DownloadedPageItem{
        .source_chapter_id = "chap-1",
        .page_number = 1,
        .url = "https://example.com/1",
        .image_data = "\x89PNG\r\n\x1a\nraw-png-data",
    };
    const png_res = try service.execute(test_alloc, png_item);
    try std.testing.expectEqualStrings("image/png", png_res.content_type);

    // JPEG
    const jpeg_item = catalog.DownloadedPageItem{
        .source_chapter_id = "chap-1",
        .page_number = 2,
        .url = "https://example.com/2",
        .image_data = "\xff\xd8\xff\xe0raw-jpeg-data",
    };
    const jpeg_res = try service.execute(test_alloc, jpeg_item);
    try std.testing.expectEqualStrings("image/jpeg", jpeg_res.content_type);

    // WebP
    const webp_item = catalog.DownloadedPageItem{
        .source_chapter_id = "chap-1",
        .page_number = 3,
        .url = "https://example.com/3",
        .image_data = "RIFF\x00\x00\x00\x00WEBPVP8Xraw-webp",
    };
    const webp_res = try service.execute(test_alloc, webp_item);
    try std.testing.expectEqualStrings("image/webp", webp_res.content_type);

    // Unknown fallback
    const unknown_item = catalog.DownloadedPageItem{
        .source_chapter_id = "chap-1",
        .page_number = 4,
        .url = "https://example.com/4",
        .image_data = "random-binary-noise-data",
    };
    const unknown_res = try service.execute(test_alloc, unknown_item);
    try std.testing.expectEqualStrings("application/octet-stream", unknown_res.content_type);

    // Static helper direct invocation
    try std.testing.expectEqualStrings("image/gif", catalog.DetectContentTypeService.detect("GIF89a..."));
}

test "DetectContentTypeService: DI injection via TestContainer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    const TestContext = struct {
        logger: abi.Logger = abi.Logger.noop(),
    };
    const TestContainer = abi.DiContainer(TestContext);

    var test_ctx = TestContext{};
    const item = catalog.DownloadedPageItem{
        .source_chapter_id = "chap-di",
        .page_number = 1,
        .url = "https://example.com/1",
        .image_data = "\x89PNG\r\n\x1a\npng-bytes",
    };

    var service = try TestContainer.inject(
        catalog.DetectContentTypeService,
        &test_ctx,
        test_alloc,
        item,
    );

    const res = try service.execute(test_alloc, item);
    try std.testing.expectEqualStrings("image/png", res.content_type);
}

// ---------------------------------------------------------------------------
// Tests for AnalyzeImageService (Simulated Static Image Analysis)
// ---------------------------------------------------------------------------

test "AnalyzeImageService: direct execution uses configurable parameters without hardcoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    var service = catalog.AnalyzeImageService{
        .logger = abi.Logger.noop(),
    };

    const input_page = catalog.PageWithContentType{
        .source_chapter_id = "chap-sim-1",
        .page_number = 3,
        .url = "https://cdn.example.org/p3.png",
        .image_data = "\x89PNG\r\n\x1a\nsample-image-bytes",
        .content_type = "image/png",
    };

    // 1. With explicit dimensions from pipeline params
    const analyzed = try service.execute(test_alloc, .{
        .item = input_page,
        .default_width = 1600,
        .default_height = 2400,
    });
    try std.testing.expectEqualStrings("chap-sim-1", analyzed.source_chapter_id);
    try std.testing.expectEqual(@as(u32, 3), analyzed.page_number);
    try std.testing.expectEqualStrings("https://cdn.example.org/p3.png", analyzed.url);
    try std.testing.expectEqualStrings("image/png", analyzed.content_type);
    try std.testing.expectEqual(@as(u32, 1600), analyzed.width);
    try std.testing.expectEqual(@as(u32, 2400), analyzed.height);
    try std.testing.expect(!analyzed.is_double_page);

    // 2. Without params: dimensions remain 0, no hardcoded magic numbers
    const unconfigured = try service.execute(test_alloc, .{
        .item = input_page,
    });
    try std.testing.expectEqual(@as(u32, 0), unconfigured.width);
    try std.testing.expectEqual(@as(u32, 0), unconfigured.height);

    // Empty payload error
    const empty_page = catalog.PageWithContentType{
        .source_chapter_id = "chap-sim-1",
        .page_number = 4,
        .url = "https://cdn.example.org/p4.png",
        .image_data = "",
        .content_type = "image/png",
    };
    try std.testing.expectError(error.EmptyImagePayload, service.execute(test_alloc, .{ .item = empty_page }));
}

test "AnalyzeImageService: DI injection via TestContainer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    const TestContext = struct {
        logger: abi.Logger = abi.Logger.noop(),
    };
    const TestContainer = abi.DiContainer(TestContext);

    var test_ctx = TestContext{};
    const item = catalog.PageWithContentType{
        .source_chapter_id = "chap-analyze-di",
        .page_number = 7,
        .url = "https://example.com/p7.webp",
        .image_data = "RIFF....WEBP...",
        .content_type = "image/webp",
    };
    const inputs = catalog.AnalyzeImageInputs{
        .item = item,
        .default_width = 1400,
        .default_height = 2100,
    };

    var service = try TestContainer.inject(
        catalog.AnalyzeImageService,
        &test_ctx,
        test_alloc,
        inputs,
    );

    const analyzed = try service.execute(test_alloc, inputs);
    try std.testing.expectEqualStrings("chap-analyze-di", analyzed.source_chapter_id);
    try std.testing.expectEqual(@as(u32, 7), analyzed.page_number);
    try std.testing.expectEqual(@as(u32, 1400), analyzed.width);
    try std.testing.expectEqual(@as(u32, 2100), analyzed.height);
}

// ---------------------------------------------------------------------------
// Tests for GenerateComicInfoService
// ---------------------------------------------------------------------------

test "GenerateComicInfoService: generates valid ComicInfo.xml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    var service = catalog.GenerateComicInfoService{
        .logger = abi.Logger.noop(),
    };

    const inputs = catalog.GenerateComicInfoInputs{
        .item = .{
            .source_chapter_id = "ch-101",
            .series_id = "ser-csm",
            .chapter_number = "101",
            .title = "Early Bird",
            .volume_number = "12",
            .language = "es",
            .page_count = 19,
        },
        .series_title = "Chainsaw Man",
        .writer = "Tatsuki Fujimoto",
        .genre = "Action, Horror",
        .manga_type = "YesAndRightToLeft",
    };

    const out = try service.execute(test_alloc, inputs);
    try std.testing.expectEqualStrings("101", out.chapter_number);
    try std.testing.expect(out.xml_data.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out.xml_data, "<Series>Chainsaw Man</Series>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.xml_data, "<Number>101</Number>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.xml_data, "<Writer>Tatsuki Fujimoto</Writer>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.xml_data, "<PageCount>19</PageCount>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.xml_data, "<LanguageISO>es</LanguageISO>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.xml_data, "<Manga>YesAndRightToLeft</Manga>") != null);
}

// ---------------------------------------------------------------------------
// Tests for BuildCbzArchiveService
// ---------------------------------------------------------------------------

test "BuildCbzArchiveService: builds readable CBZ archive with ComicInfo.xml and pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    const cbz_path = "/tmp/test_build_cbz_service.cbz";
    _ = std.c.unlink(cbz_path);
    defer _ = std.c.unlink(cbz_path);

    var service = catalog.BuildCbzArchiveService{
        .logger = abi.Logger.noop(),
    };

    const pages = [_]catalog.PageWithContentType{
        .{
            .source_chapter_id = "ch-cbz-1",
            .page_number = 1,
            .url = "https://cdn.example.com/1.png",
            .image_data = "\x89PNG\r\n\x1a\npage-1-bytes",
            .content_type = "image/png",
        },
        .{
            .source_chapter_id = "ch-cbz-1",
            .page_number = 2,
            .url = "https://cdn.example.com/2.jpg",
            .image_data = "\xff\xd8\xff\xe0page-2-bytes",
            .content_type = "image/jpeg",
        },
    };

    const comic_infos = [_]catalog.ComicInfoOutput{
        .{
            .chapter_number = "1",
            .xml_data = "<ComicInfo><Series>Test</Series><Number>1</Number></ComicInfo>",
        },
    };

    const outs = try service.execute(test_alloc, .{
        .pages = &pages,
        .comic_infos = &comic_infos,
        .output_path = cbz_path,
    });
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    const out = outs[0];

    try std.testing.expectEqualStrings(cbz_path, out.archive_path);
    try std.testing.expectEqual(@as(u32, 2), out.total_pages);
    try std.testing.expect(out.file_size_bytes > 0);

    // Verify reading archive back with ZipArchiveReader
    const zip_archive = @import("zip_archive");
    var reader = try zip_archive.ZipArchiveReader.openFile(test_alloc, cbz_path);
    defer reader.deinit();

    // 1 XML + 2 image pages = 3 entries
    try std.testing.expectEqual(@as(usize, 3), reader.getNumFiles());

    var name_buf: [128]u8 = undefined;
    const name0 = (try reader.getFileName(0, &name_buf)).?;
    try std.testing.expectEqualStrings("ComicInfo.xml", name0);

    const name1 = (try reader.getFileName(1, &name_buf)).?;
    try std.testing.expectEqualStrings("001.png", name1);

    const name2 = (try reader.getFileName(2, &name_buf)).?;
    try std.testing.expectEqualStrings("002.jpg", name2);
}

test "BuildCbzArchiveService: resolves {chapter} placeholder in output_dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    const expected_cbz = "/tmp/test_dir_templating/42/chapter_42.cbz";
    _ = std.c.unlink(expected_cbz);
    defer _ = std.c.unlink(expected_cbz);

    var service = catalog.BuildCbzArchiveService{
        .logger = abi.Logger.noop(),
    };

    const pages = [_]catalog.PageWithContentType{
        .{
            .source_chapter_id = "ch-cbz-42",
            .chapter_number = "42",
            .page_number = 1,
            .url = "https://cdn.example.com/1.png",
            .image_data = "\x89PNG\r\n\x1a\npage-1-bytes",
            .content_type = "image/png",
        },
    };

    const outs = try service.execute(test_alloc, .{
        .pages = &pages,
        .comic_infos = &.{},
        .output_dir = "/tmp/test_dir_templating/{chapter}",
    });
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    const out = outs[0];

    try std.testing.expectEqualStrings(expected_cbz, out.archive_path);
    try std.testing.expectEqual(@as(u32, 1), out.total_pages);
}

test "BuildCbzArchiveService: builds in-memory CBZ archive without writing to disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    var service = catalog.BuildCbzArchiveService{
        .logger = abi.Logger.noop(),
    };

    const pages = [_]catalog.PageWithContentType{
        .{
            .source_chapter_id = "ch-mem-1",
            .series_id = "ser-uuid-1",
            .chapter_number = "7",
            .page_number = 1,
            .url = "https://cdn.example.com/1.png",
            .image_data = "\x89PNG\r\n\x1a\npage-1-bytes",
            .content_type = "image/png",
        },
    };

    const comic_infos = [_]catalog.ComicInfoOutput{
        .{
            .chapter_number = "7",
            .xml_data = "<ComicInfo><Series>Plastic Neesan</Series></ComicInfo>",
        },
    };

    const outs = try service.execute(test_alloc, .{
        .pages = &pages,
        .comic_infos = &comic_infos,
        .in_memory = true,
        .series_title = "Plastic Neesan",
        .library = "Seinen",
    });

    try std.testing.expectEqual(@as(usize, 1), outs.len);
    try std.testing.expectEqualStrings("", outs[0].archive_path);
    try std.testing.expectEqualStrings("chapter_7.cbz", outs[0].filename);
    try std.testing.expectEqualStrings("Plastic Neesan", outs[0].series);
    try std.testing.expectEqualStrings("Seinen", outs[0].library);
    try std.testing.expect(outs[0].data.len > 0);
    try std.testing.expectEqual(@as(u64, outs[0].data.len), outs[0].file_size_bytes);
    // Standard ZIP magic header 'PK\x03\x04'
    try std.testing.expect(std.mem.startsWith(u8, outs[0].data, "PK\x03\x04"));
}

test "matchesChapterFilter handles ranges, slices, and exact matches" {
    const matches = catalog.task_chapters.matchesChapterFilter;

    // All / wildcard
    try std.testing.expect(matches("1", "all"));
    try std.testing.expect(matches("99", "*"));
    try std.testing.expect(matches("3.5", ""));

    // Exact matches and comma-separated
    try std.testing.expect(matches("1", "1"));
    try std.testing.expect(matches("2", "1, 2, 3"));
    try std.testing.expect(!matches("4", "1, 2, 3"));

    // Slice / open-ended range from N to end ("2:", "2..", "2-")
    try std.testing.expect(!matches("1", "2:"));
    try std.testing.expect(matches("2", "2:"));
    try std.testing.expect(matches("2.5", "2:"));
    try std.testing.expect(matches("100", "2:"));

    try std.testing.expect(!matches("1", "2.."));
    try std.testing.expect(matches("2", "2.."));
    try std.testing.expect(matches("100", "2.."));

    try std.testing.expect(!matches("1", "2-"));
    try std.testing.expect(matches("2", "2-"));
    try std.testing.expect(matches("100", "2-"));

    // Bounded inclusive ranges ("2:5", "2..5", "2...5", "2-5") - both bounds included
    try std.testing.expect(!matches("1", "2:5"));
    try std.testing.expect(matches("2", "2:5"));
    try std.testing.expect(matches("3.5", "2..5"));
    try std.testing.expect(matches("5", "2..5"));
    try std.testing.expect(matches("2", "2...5"));
    try std.testing.expect(matches("5", "2...5"));
    try std.testing.expect(matches("2", "2-5"));
    try std.testing.expect(matches("5", "2-5"));
    try std.testing.expect(!matches("6", "2-5"));

    // Open-ended range from start to N (":5", "..5", "-5")
    try std.testing.expect(matches("1", ":5"));
    try std.testing.expect(matches("5", "..5"));
    try std.testing.expect(!matches("5.1", "-5"));

    // User-friendly "+" suffix and comparison operators
    try std.testing.expect(!matches("1", "2+"));
    try std.testing.expect(matches("2", "2+"));
    try std.testing.expect(matches("100", "2+"));

    try std.testing.expect(matches("2", ">=2"));
    try std.testing.expect(!matches("1.9", ">=2"));
    try std.testing.expect(!matches("2", ">2"));
    try std.testing.expect(matches("2.1", ">2"));

    try std.testing.expect(matches("5", "<=5"));
    try std.testing.expect(!matches("5.1", "<=5"));
    try std.testing.expect(!matches("5", "<5"));
    try std.testing.expect(matches("4.9", "<5"));
}

test "DownloadCoverService: downloads cover and detects extension from magic bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_alloc = arena.allocator();

    const MockCoverHttp = struct {
        fn execute(_: *anyopaque, alloc: std.mem.Allocator, _: sdk.HttpMethod, _: []const u8, _: []const sdk.HttpHeader, _: []const u8) error{ InvalidUrl, NetworkFailure, OutOfMemory, RateLimited, Timeout }!sdk.HttpResponse {
            return .{
                .status_code = 200,
                .body = try alloc.dupe(u8, "\x89PNG\r\n\x1a\nfake-png-cover"),
            };
        }
    };
    var dummy: u8 = 0;
    const http = sdk.HttpTransport{
        .ptr = &dummy,
        .vtable = &.{ .execute = MockCoverHttp.execute },
    };

    var svc = catalog.DownloadCoverService{
        .http = http,
        .logger = abi.Logger.noop(),
    };

    const cbz_list = [_]catalog.CbzArchiveOutput{
        .{
            .filename = "chapter_15.cbz",
            .series_id = "s-1",
            .series = "The Ghostly Doctor",
            .library = "manga",
            .chapter_number = "15",
            .total_pages = 7,
            .file_size_bytes = 1234,
        },
    };

    // Missing cover_url returns empty slice gracefully
    const empty_res = try svc.execute(test_alloc, .{
        .cbz_archive = &cbz_list,
        .series_id = "s-1",
        .title = "The Ghostly Doctor",
        .cover_url = null,
    });
    try std.testing.expectEqual(@as(usize, 0), empty_res.len);

    // Valid PNG cover_url emits CoverOutput with ext + chapter_number for pipeline.yaml routing
    const res = try svc.execute(test_alloc, .{
        .cbz_archive = &cbz_list,
        .series_id = "s-1",
        .title = "The Ghostly Doctor",
        .cover_url = "https://uploads.mangadex.org/covers/s-1/cover.png",
        .library = "manga",
    });
    try std.testing.expectEqual(@as(usize, 1), res.len);
    try std.testing.expectEqualStrings("png", res[0].ext);
    try std.testing.expectEqualStrings("15", res[0].chapter_number);
    try std.testing.expectEqualStrings("The Ghostly Doctor", res[0].series);
    try std.testing.expectEqualStrings("manga", res[0].library);
    try std.testing.expect(std.mem.startsWith(u8, res[0].data, "\x89PNG"));
}
