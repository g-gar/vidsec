const std = @import("std");
const Allocator = std.mem.Allocator;

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,

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
