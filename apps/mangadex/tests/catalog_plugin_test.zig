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
    try std.testing.expectEqual(@as(usize, 3), manifest.tasks_len);

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
