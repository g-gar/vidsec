const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const auth = @import("auth.zig");
const types = @import("types.zig");

const HttpTransport = http.HttpTransport;
const HttpMethod = http.HttpMethod;
const HttpHeader = http.HttpHeader;
const HttpResponse = http.HttpResponse;
const KomgaAuth = auth.KomgaAuth;

const UserDto = types.UserDto;
const LibraryDto = types.LibraryDto;
const SeriesDto = types.SeriesDto;
const BookDto = types.BookDto;
const BookImportBatchDto = types.BookImportBatchDto;
const PageDto = types.PageDto;

pub const ClientConfig = struct {
    base_url: []const u8 = "http://localhost:25600",
    auth: KomgaAuth = .none,
    user_agent: []const u8 = "flowdata-komga-sdk/0.1.0",
};

pub const KomgaClientError = error{
    HttpError,
    NotFound,
    Unauthorized,
    Forbidden,
    InvalidResponse,
    OutOfMemory,
};

pub const KomgaClient = struct {
    allocator: Allocator,
    config: ClientConfig,
    transport: HttpTransport,

    pub fn init(allocator: Allocator, config: ClientConfig, transport: HttpTransport) KomgaClient {
        return .{
            .allocator = allocator,
            .config = config,
            .transport = transport,
        };
    }

    fn request(
        self: *KomgaClient,
        method: HttpMethod,
        path: []const u8,
        body: []const u8,
    ) !HttpResponse {
        var headers: std.ArrayListUnmanaged(HttpHeader) = .empty;
        defer headers.deinit(self.allocator);

        try headers.append(self.allocator, .{
            .name = "User-Agent",
            .value = self.config.user_agent,
        });

        if (body.len > 0) {
            try headers.append(self.allocator, .{
                .name = "Content-Type",
                .value = "application/json",
            });
        }

        try self.config.auth.applyHeaders(self.allocator, &headers);

        const trimmed_base = std.mem.trimEnd(u8, self.config.base_url, "/");
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ trimmed_base, path });
        defer self.allocator.free(url);

        const resp = self.transport.execute(self.allocator, method, url, headers.items, body) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.HttpError,
            };
        };

        if (resp.status_code == 401) return error.Unauthorized;
        if (resp.status_code == 403) return error.Forbidden;
        if (resp.status_code == 404) return error.NotFound;
        if (resp.status_code >= 400) return error.HttpError;

        return resp;
    }

    // =========================================================================
    // 1. Health & Identity
    // =========================================================================

    pub fn getMe(self: *KomgaClient) !std.json.Parsed(UserDto) {
        const resp = try self.request(.GET, "/api/v2/users/me", "");
        return std.json.parseFromSlice(UserDto, self.allocator, resp.body, .{
            .ignore_unknown_fields = true,
        }) catch error.InvalidResponse;
    }

    // =========================================================================
    // 2. Libraries
    // =========================================================================

    pub fn listLibraries(self: *KomgaClient) !std.json.Parsed([]LibraryDto) {
        const resp = try self.request(.GET, "/api/v1/libraries", "");
        return std.json.parseFromSlice([]LibraryDto, self.allocator, resp.body, .{
            .ignore_unknown_fields = true,
        }) catch error.InvalidResponse;
    }

    pub fn scanLibrary(self: *KomgaClient, library_id: []const u8, deep: bool) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/api/v1/libraries/{s}/scan?deep={s}", .{
            library_id,
            if (deep) "true" else "false",
        });
        defer self.allocator.free(path);

        _ = try self.request(.POST, path, "");
    }

    pub fn emptyTrash(self: *KomgaClient, library_id: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/api/v1/libraries/{s}/empty-trash", .{library_id});
        defer self.allocator.free(path);

        _ = try self.request(.POST, path, "");
    }

    // =========================================================================
    // 3. Series
    // =========================================================================

    fn appendPercentEncoded(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), input: []const u8) !void {
        const hex_chars = "0123456789ABCDEF";
        for (input) |byte| {
            if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
                try out.append(allocator, byte);
            } else {
                try out.append(allocator, '%');
                try out.append(allocator, hex_chars[byte >> 4]);
                try out.append(allocator, hex_chars[byte & 0x0F]);
            }
        }
    }

    pub fn searchSeries(self: *KomgaClient, title: []const u8, library_id: ?[]const u8) !std.json.Parsed(PageDto(SeriesDto)) {
        var path_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer path_buf.deinit(self.allocator);

        try path_buf.appendSlice(self.allocator, "/api/v1/series?search=");
        try appendPercentEncoded(self.allocator, &path_buf, title);

        if (library_id) |lib_id| {
            try path_buf.appendSlice(self.allocator, "&library_id=");
            try appendPercentEncoded(self.allocator, &path_buf, lib_id);
        }

        const resp = try self.request(.GET, path_buf.items, "");
        return std.json.parseFromSlice(PageDto(SeriesDto), self.allocator, resp.body, .{
            .ignore_unknown_fields = true,
        }) catch error.InvalidResponse;
    }

    pub fn getSeries(self: *KomgaClient, series_id: []const u8) !std.json.Parsed(SeriesDto) {
        const path = try std.fmt.allocPrint(self.allocator, "/api/v1/series/{s}", .{series_id});
        defer self.allocator.free(path);

        const resp = try self.request(.GET, path, "");
        return std.json.parseFromSlice(SeriesDto, self.allocator, resp.body, .{
            .ignore_unknown_fields = true,
        }) catch error.InvalidResponse;
    }

    pub fn analyzeSeries(self: *KomgaClient, series_id: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/api/v1/series/{s}/analyze", .{series_id});
        defer self.allocator.free(path);

        _ = try self.request(.POST, path, "");
    }

    // =========================================================================
    // 4. Books & Import
    // =========================================================================

    pub fn getBook(self: *KomgaClient, book_id: []const u8) !std.json.Parsed(BookDto) {
        const path = try std.fmt.allocPrint(self.allocator, "/api/v1/books/{s}", .{book_id});
        defer self.allocator.free(path);

        const resp = try self.request(.GET, path, "");
        return std.json.parseFromSlice(BookDto, self.allocator, resp.body, .{
            .ignore_unknown_fields = true,
        }) catch error.InvalidResponse;
    }

    pub fn importBooks(self: *KomgaClient, batch: BookImportBatchDto) !void {
        const body = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(batch, .{})});
        defer self.allocator.free(body);
        _ = try self.request(.POST, "/api/v1/books/import", body);
    }
};
