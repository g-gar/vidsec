const std = @import("std");
const komga_sdk = @import("komga_sdk");
const KomgaClient = komga_sdk.KomgaClient;
const KomgaAuth = komga_sdk.KomgaAuth;
const HttpTransport = komga_sdk.HttpTransport;
const HttpMethod = komga_sdk.HttpMethod;
const HttpHeader = komga_sdk.HttpHeader;
const HttpResponse = komga_sdk.HttpResponse;
const HttpTransportError = komga_sdk.HttpTransportError;
const CopyMode = komga_sdk.CopyMode;

const MockKomgaTransport = struct {
    last_method: ?HttpMethod = null,
    last_url: ?[]const u8 = null,
    last_auth_header: ?[]const u8 = null,
    last_body: ?[]const u8 = null,

    pub fn httpTransport(self: *MockKomgaTransport) HttpTransport {
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
        const self: *MockKomgaTransport = @ptrCast(@alignCast(ctx));
        self.last_method = method;

        if (self.last_url) |u| allocator.free(u);
        self.last_url = allocator.dupe(u8, url) catch return error.OutOfMemory;

        if (self.last_body) |b| allocator.free(b);
        self.last_body = allocator.dupe(u8, body) catch return error.OutOfMemory;

        for (headers) |h| {
            if (std.mem.eql(u8, h.name, "Authorization") or std.mem.eql(u8, h.name, "X-API-Key")) {
                if (self.last_auth_header) |a| allocator.free(a);
                self.last_auth_header = allocator.dupe(u8, h.value) catch return error.OutOfMemory;
            }
        }

        // 1. Health / Users Me
        if (std.mem.indexOf(u8, url, "/api/v2/users/me") != null) {
            return .{
                .status_code = 200,
                .body =
                    \\{"id":"user-1","email":"admin@komga.org","roles":["ADMIN"],"sharedAllLibraries":true}
                ,
            };
        }

        // 2. Libraries
        if (std.mem.indexOf(u8, url, "/api/v1/libraries") != null and std.mem.indexOf(u8, url, "/scan") == null and std.mem.indexOf(u8, url, "/empty-trash") == null) {
            return .{
                .status_code = 200,
                .body =
                    \\[{"id":"lib-1","name":"Manga Library","root":"/data/manga","importComicInfoBook":true,"scanInterval":"0 0 * * * ?"}]
                ,
            };
        }

        if (std.mem.indexOf(u8, url, "/scan") != null) {
            return .{
                .status_code = 204,
                .body = "",
            };
        }

        if (std.mem.indexOf(u8, url, "/empty-trash") != null) {
            return .{
                .status_code = 204,
                .body = "",
            };
        }

        // 3. Series
        if (std.mem.indexOf(u8, url, "/api/v1/series/ser-123/analyze") != null) {
            return .{
                .status_code = 204,
                .body = "",
            };
        }

        if (std.mem.indexOf(u8, url, "/api/v1/series/ser-123") != null) {
            return .{
                .status_code = 200,
                .body =
                    \\{"id":"ser-123","libraryId":"lib-1","name":"Chainsaw Man","booksCount":15,"deleted":false}
                ,
            };
        }

        if (std.mem.indexOf(u8, url, "/api/v1/series?search=") != null) {
            return .{
                .status_code = 200,
                .body =
                    \\{"content":[{"id":"ser-123","libraryId":"lib-1","name":"Chainsaw Man","booksCount":15,"deleted":false}],"empty":false,"first":true,"last":true,"number":0,"numberOfElements":1,"size":20,"totalElements":1,"totalPages":1}
                ,
            };
        }

        // 4. Books & Import
        if (std.mem.indexOf(u8, url, "/api/v1/books/import") != null) {
            return .{
                .status_code = 202,
                .body = "",
            };
        }

        if (std.mem.indexOf(u8, url, "/api/v1/books/book-456") != null) {
            return .{
                .status_code = 200,
                .body =
                    \\{"id":"book-456","seriesId":"ser-123","name":"Chapter 1","number":1.0,"sizeBytes":15243000,"media":{"status":"READY","pagesCount":24},"deleted":false}
                ,
            };
        }

        return .{
            .status_code = 404,
            .body = "{\"error\":\"not found\"}",
        };
    }
};

test "KomgaAuth applies API Key and Basic Auth headers correctly" {
    const alloc = std.testing.allocator;

    // 1. API Key Auth
    const key_auth = KomgaAuth{ .api_key = "my-secret-key-123" };
    var headers1: std.ArrayListUnmanaged(HttpHeader) = .empty;
    defer headers1.deinit(alloc);
    try key_auth.applyHeaders(alloc, &headers1);
    try std.testing.expectEqual(@as(usize, 1), headers1.items.len);
    try std.testing.expectEqualStrings("X-API-Key", headers1.items[0].name);
    try std.testing.expectEqualStrings("my-secret-key-123", headers1.items[0].value);

    // 2. Basic Auth (RFC 7617 base64 encoding)
    const basic_auth = KomgaAuth{ .basic_auth = .{
        .username = "admin",
        .password = "secret",
    } };
    var headers2: std.ArrayListUnmanaged(HttpHeader) = .empty;
    defer {
        for (headers2.items) |h| alloc.free(h.value);
        headers2.deinit(alloc);
    }
    try basic_auth.applyHeaders(alloc, &headers2);
    try std.testing.expectEqual(@as(usize, 1), headers2.items.len);
    try std.testing.expectEqualStrings("Authorization", headers2.items[0].name);
    // "admin:secret" -> "YWRtaW46c2VjcmV0"
    try std.testing.expectEqualStrings("Basic YWRtaW46c2VjcmV0", headers2.items[0].value);
}

test "KomgaClient executes Library, Series and Book operations" {
    const alloc = std.testing.allocator;
    var mock = MockKomgaTransport{};
    defer {
        if (mock.last_url) |u| alloc.free(u);
        if (mock.last_body) |b| alloc.free(b);
        if (mock.last_auth_header) |a| alloc.free(a);
    }

    var client = KomgaClient.init(alloc, .{
        .base_url = "http://127.0.0.1:25600",
        .auth = .{ .api_key = "test-token" },
    }, mock.httpTransport());

    // 1. GetMe (Users Me)
    var me = try client.getMe();
    defer me.deinit();
    try std.testing.expectEqualStrings("user-1", me.value.id);
    try std.testing.expectEqualStrings("admin@komga.org", me.value.email);

    // 2. List Libraries
    var libs = try client.listLibraries();
    defer libs.deinit();
    try std.testing.expectEqual(@as(usize, 1), libs.value.len);
    try std.testing.expectEqualStrings("lib-1", libs.value[0].id);
    try std.testing.expectEqualStrings("Manga Library", libs.value[0].name);

    // 3. Scan Library
    try client.scanLibrary("lib-1", true);
    try std.testing.expectEqual(HttpMethod.POST, mock.last_method.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:25600/api/v1/libraries/lib-1/scan?deep=true", mock.last_url.?);

    // 4. Empty Trash
    try client.emptyTrash("lib-1");
    try std.testing.expectEqual(HttpMethod.POST, mock.last_method.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:25600/api/v1/libraries/lib-1/empty-trash", mock.last_url.?);

    // 5. Search Series
    var search_res = try client.searchSeries("Chainsaw", "lib-1");
    defer search_res.deinit();
    try std.testing.expectEqual(@as(usize, 1), search_res.value.content.len);
    try std.testing.expectEqualStrings("ser-123", search_res.value.content[0].id);
    try std.testing.expectEqualStrings("Chainsaw Man", search_res.value.content[0].name);

    var encoded_search = try client.searchSeries("The Ghostly Doctor", "lib-1");
    defer encoded_search.deinit();
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:25600/api/v1/series?search=The%20Ghostly%20Doctor&library_id=lib-1",
        mock.last_url.?,
    );

    // 6. Get Series & Analyze Series
    var series = try client.getSeries("ser-123");
    defer series.deinit();
    try std.testing.expectEqualStrings("ser-123", series.value.id);
    try std.testing.expectEqual(@as(u32, 15), series.value.booksCount);

    try client.analyzeSeries("ser-123");
    try std.testing.expectEqual(HttpMethod.POST, mock.last_method.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:25600/api/v1/series/ser-123/analyze", mock.last_url.?);

    // 7. Get Book
    var book = try client.getBook("book-456");
    defer book.deinit();
    try std.testing.expectEqualStrings("book-456", book.value.id);
    try std.testing.expectEqualStrings("Chapter 1", book.value.name);
    try std.testing.expectEqual(@as(u32, 24), book.value.media.pagesCount);

    // 8. Import Books Batch
    const import_batch = komga_sdk.BookImportBatchDto{
        .copyMode = .MOVE,
        .books = &.{
            .{
                .seriesId = "ser-123",
                .sourceFile = "/tmp/chainsaw_man_c01.cbz",
                .destinationName = "Chainsaw Man - c01.cbz",
            },
        },
    };
    try client.importBooks(import_batch);
    try std.testing.expectEqual(HttpMethod.POST, mock.last_method.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:25600/api/v1/books/import", mock.last_url.?);
    try std.testing.expect(mock.last_body != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"copyMode\":\"MOVE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "\"seriesId\":\"ser-123\"") != null);
}

test "UploadCbzService resolves library, scans, analyzes series and emits egress_history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mock = MockKomgaTransport{};
    var client = KomgaClient.init(alloc, .{
        .base_url = "http://127.0.0.1:25600",
        .auth = .{ .api_key = "test-token" },
    }, mock.httpTransport());

    const flowdata = @import("flowdata");
    const catalog = @import("mangadex_app").catalog;

    var service = catalog.UploadCbzService{
        .komga = &client,
        .logger = flowdata.plugin.Logger.noop(),
        .default_library_id = "lib-1",
    };

    const archives = [_]catalog.CbzArchiveOutput{
        .{
            .filename = "chapter_1.cbz",
            .series_id = "md-uuid-1",
            .series = "Chainsaw Man",
            .library = "Manga Library",
            .chapter_number = "1",
            .data = "PK\x03\x04dummy",
            .total_pages = 24,
            .file_size_bytes = 10,
        },
    };

    const records = try service.execute(alloc, .{
        .cbz_archive = &archives,
        .series_title = "Chainsaw Man",
        .library = "Manga Library",
    });

    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("komga", records[0].target);
    try std.testing.expectEqualStrings("ser-123", records[0].external_book_id.?);
    try std.testing.expectEqualStrings("success", records[0].status);
    try std.testing.expectEqual(HttpMethod.POST, mock.last_method.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:25600/api/v1/series/ser-123/analyze", mock.last_url.?);
}
