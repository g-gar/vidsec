const std = @import("std");
const sdk = @import("mangadex_sdk");
const PersonalClientAuth = sdk.PersonalClientAuth;
const StaticTokenAuth = sdk.StaticTokenAuth;
const HttpTransport = sdk.HttpTransport;
const HttpMethod = sdk.HttpMethod;
const HttpHeader = sdk.HttpHeader;
const HttpResponse = sdk.HttpResponse;
const HttpTransportError = sdk.HttpTransportError;

const MockAuthTransport = struct {
    last_url: ?[]const u8 = null,
    last_body: ?[]const u8 = null,
    call_count: usize = 0,
    response_token: []const u8 = "initial_token",
    response_expires_in: u64 = 900,
    allocated_responses: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn httpTransport(self: *MockAuthTransport) HttpTransport {
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
        const self: *MockAuthTransport = @ptrCast(@alignCast(ctx));
        _ = headers;
        _ = method;

        if (self.last_url) |u| allocator.free(u);
        if (self.last_body) |b| allocator.free(b);

        self.last_url = allocator.dupe(u8, url) catch return error.OutOfMemory;
        self.last_body = allocator.dupe(u8, body) catch return error.OutOfMemory;
        self.call_count += 1;

        const token = if (self.call_count == 1) "access_tok_one" else "access_tok_refreshed";
        const refresh_token = if (self.call_count == 1) "ref_tok_one" else "ref_tok_refreshed";

        const resp_json = std.fmt.allocPrint(
            allocator,
            \\{{"access_token":"{s}","refresh_token":"{s}","expires_in":{d},"token_type":"Bearer"}}
        ,
            .{ token, refresh_token, self.response_expires_in },
        ) catch return error.OutOfMemory;

        self.allocated_responses.append(allocator, resp_json) catch return error.OutOfMemory;

        return .{
            .status_code = 200,
            .body = resp_json,
        };
    }

    pub fn deinit(self: *MockAuthTransport, allocator: std.mem.Allocator) void {
        if (self.last_url) |u| allocator.free(u);
        if (self.last_body) |b| allocator.free(b);
        for (self.allocated_responses.items) |r| {
            allocator.free(r);
        }
        self.allocated_responses.deinit(allocator);
    }
};

test "StaticTokenAuth yields Bearer header" {
    const allocator = std.testing.allocator;
    var auth_prov = try StaticTokenAuth.create(allocator, "static_token_value_abc");
    defer auth_prov.deinit();

    var mock = MockAuthTransport{};
    defer mock.deinit(allocator);

    const hdr = try auth_prov.getAuthorizationHeader(mock.httpTransport(), 1000);
    try std.testing.expect(hdr != null);
    try std.testing.expectEqualStrings("Bearer static_token_value_abc", hdr.?);
}

test "PersonalClientAuth logs in with percent-encoded special characters in password" {
    const allocator = std.testing.allocator;
    var mock = MockAuthTransport{};
    defer mock.deinit(allocator);

    var auth_prov = try PersonalClientAuth.create(allocator, .{
        .client_id = "test-client",
        .client_secret = "secret&key=1",
        .username = "user@test.org",
        .password = "P@ss#w0rd!&=",
    });
    defer auth_prov.deinit();

    const now_ms: u64 = 100_000;
    const hdr = try auth_prov.getAuthorizationHeader(mock.httpTransport(), now_ms);
    try std.testing.expect(hdr != null);
    try std.testing.expectEqualStrings("Bearer access_tok_one", hdr.?);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    // Verify percent encoding of special characters in body
    try std.testing.expect(mock.last_body != null);
    const body = mock.last_body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "grant_type=password") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "user%40test.org") != null);
    // '@' is %40, '#' is %23, '&' is %26, '=' is %3D
    try std.testing.expect(std.mem.indexOf(u8, body, "P%40ss%23w0rd%21%26%3D") != null);
}

test "PersonalClientAuth auto-refreshes token when fewer than 60s remain" {
    const allocator = std.testing.allocator;
    var mock = MockAuthTransport{
        .response_expires_in = 100, // 100 seconds
    };
    defer mock.deinit(allocator);

    var auth_prov = try PersonalClientAuth.create(allocator, .{
        .client_id = "test-client",
        .client_secret = "secret",
        .username = "user",
        .password = "pass",
    });
    defer auth_prov.deinit();

    const start_ms: u64 = 1_000_000;
    // 1st call: login
    const hdr1 = try auth_prov.getAuthorizationHeader(mock.httpTransport(), start_ms);
    try std.testing.expectEqualStrings("Bearer access_tok_one", hdr1.?);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    // 2nd call: 30 seconds later (70s remain before expiration > 60s) -> no refresh
    const hdr2 = try auth_prov.getAuthorizationHeader(mock.httpTransport(), start_ms + 30_000);
    try std.testing.expectEqualStrings("Bearer access_tok_one", hdr2.?);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    // 3rd call: 50 seconds later (50s remain < 60s) -> proactive refresh!
    const hdr3 = try auth_prov.getAuthorizationHeader(mock.httpTransport(), start_ms + 50_000);
    try std.testing.expectEqualStrings("Bearer access_tok_refreshed", hdr3.?);
    try std.testing.expectEqual(@as(usize, 2), mock.call_count);

    // Verify refresh body used grant_type=refresh_token
    try std.testing.expect(mock.last_body != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "grant_type=refresh_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_body.?, "refresh_token=ref_tok_one") != null);
}
