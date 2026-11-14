const std = @import("std");
const Allocator = std.mem.Allocator;

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,

    pub fn asText(self: HttpMethod) []const u8 {
        return @tagName(self);
    }
};

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpResponse = struct {
    status_code: u16,
    body: []const u8,
    retry_after_ms: u64 = 0,
};

pub const HttpTransportError = error{
    NetworkFailure,
    Timeout,
    RateLimited,
    InvalidUrl,
    OutOfMemory,
};

pub const HttpTransport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (
            ctx: *anyopaque,
            allocator: Allocator,
            method: HttpMethod,
            url: []const u8,
            headers: []const HttpHeader,
            body: []const u8,
        ) HttpTransportError!HttpResponse,
    };

    pub fn execute(
        self: HttpTransport,
        allocator: Allocator,
        method: HttpMethod,
        url: []const u8,
        headers: []const HttpHeader,
        body: []const u8,
    ) HttpTransportError!HttpResponse {
        return self.vtable.execute(self.ptr, allocator, method, url, headers, body);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "httpTransport")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn httpTransport(*" ++ @typeName(T) ++ ") HttpTransport'");
            }
        }
    }
};

/// Percent-encode RFC 3986 unreserved characters (ALPHA / DIGIT / "-" / "." / "_" / "~").
pub fn percentEncode(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

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

    return out.toOwnedSlice(allocator);
}

/// Encode key-value pairs into application/x-www-form-urlencoded format.
pub fn formUrlEncode(allocator: Allocator, entries: []const [2][]const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (entries, 0..) |entry, i| {
        if (i > 0) try out.append(allocator, '&');
        const enc_k = try percentEncode(allocator, entry[0]);
        defer allocator.free(enc_k);
        const enc_v = try percentEncode(allocator, entry[1]);
        defer allocator.free(enc_v);

        try out.appendSlice(allocator, enc_k);
        try out.append(allocator, '=');
        try out.appendSlice(allocator, enc_v);
    }

    return out.toOwnedSlice(allocator);
}

/// Builder for MangaDex API query strings, supporting bracketed array syntax (e.g. `includes[]=author`).
pub const QueryBuilder = struct {
    allocator: Allocator,
    params: std.ArrayListUnmanaged([2][]const u8) = .empty,

    pub fn init(allocator: Allocator) QueryBuilder {
        return .{
            .allocator = allocator,
            .params = .empty,
        };
    }

    pub fn deinit(self: *QueryBuilder) void {
        for (self.params.items) |p| {
            self.allocator.free(p[0]);
            self.allocator.free(p[1]);
        }
        self.params.deinit(self.allocator);
    }

    pub fn addParam(self: *QueryBuilder, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(v);
        try self.params.append(self.allocator, .{ k, v });
    }

    pub fn addInt(self: *QueryBuilder, key: []const u8, value: anytype) !void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutOfMemory;
        try self.addParam(key, s);
    }

    pub fn addArrayParam(self: *QueryBuilder, base_key: []const u8, items: []const []const u8) !void {
        if (items.len == 0) return;
        const key_with_brackets = if (std.mem.endsWith(u8, base_key, "[]"))
            try self.allocator.dupe(u8, base_key)
        else
            try std.fmt.allocPrint(self.allocator, "{s}[]", .{base_key});
        defer self.allocator.free(key_with_brackets);

        for (items) |item| {
            try self.addParam(key_with_brackets, item);
        }
    }

    pub fn buildUrl(self: *QueryBuilder, base_url: []const u8) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        try out.appendSlice(self.allocator, base_url);

        if (self.params.items.len > 0) {
            const has_query = std.mem.indexOfScalar(u8, base_url, '?') != null;
            try out.append(self.allocator, if (has_query) '&' else '?');

            for (self.params.items, 0..) |p, i| {
                if (i > 0) try out.append(self.allocator, '&');
                // Note: For query parameter keys with [], we keep [] intact or percent-encode per API
                // MangaDex accepts both `includes[]=` and `includes%5B%5D=`. Standard practice is raw `[]`
                try out.appendSlice(self.allocator, p[0]);
                try out.append(self.allocator, '=');
                const enc_v = try percentEncode(self.allocator, p[1]);
                defer self.allocator.free(enc_v);
                try out.appendSlice(self.allocator, enc_v);
            }
        }

        return out.toOwnedSlice(self.allocator);
    }
};
