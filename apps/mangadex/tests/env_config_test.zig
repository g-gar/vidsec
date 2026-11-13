const std = @import("std");
const flowdata = @import("flowdata");
const EnvInterpolator = flowdata.yaml.EnvInterpolator;
const AppConfig = @import("mangadex_app").AppConfig;
const sdk = @import("mangadex_sdk");

test "AppConfig.resolveAuthProvider selects StaticTokenAuth when MANGADEX_ACCESS_TOKEN is set" {
    const allocator = std.testing.allocator;
    var interp = EnvInterpolator.init(false);
    defer interp.deinit(allocator);

    try interp.put(allocator, "MANGADEX_ACCESS_TOKEN", "mock_static_jwt_123");

    const cfg = AppConfig{};
    var provider = (try cfg.resolveAuthProvider(allocator, &interp)).?;
    defer provider.deinit();

    // Mock transport
    var mock_transport = DummyTransport{};
    const header = try provider.getAuthorizationHeader(mock_transport.httpTransport(), 1000);
    try std.testing.expect(header != null);
    try std.testing.expectEqualStrings("Bearer mock_static_jwt_123", header.?);
}

test "AppConfig.resolveAuthProvider selects PersonalClientAuth when credentials are provided" {
    const allocator = std.testing.allocator;
    var interp = EnvInterpolator.init(false);
    defer interp.deinit(allocator);

    try interp.put(allocator, "MANGADEX_CLIENT_ID", "personal-client-xyz");
    try interp.put(allocator, "MANGADEX_CLIENT_SECRET", "super_secret");
    try interp.put(allocator, "MANGADEX_USERNAME", "testuser");
    try interp.put(allocator, "MANGADEX_PASSWORD", "secret#pass@123");

    const cfg = AppConfig{};
    var provider = (try cfg.resolveAuthProvider(allocator, &interp)).?;
    defer provider.deinit();

    var mock_transport = DummyTransport{};
    const header = try provider.getAuthorizationHeader(mock_transport.httpTransport(), 1000);
    try std.testing.expect(header != null);
    try std.testing.expectEqualStrings("Bearer tok123", header.?);
}

test "AppConfig.resolveAuthProvider returns null (anonymous mode) when no credentials are configured" {
    const allocator = std.testing.allocator;
    var interp = EnvInterpolator.init(false);
    defer interp.deinit(allocator);

    const cfg = AppConfig{};
    const provider = try cfg.resolveAuthProvider(allocator, &interp);
    try std.testing.expect(provider == null);
}

const DummyTransport = struct {
    pub fn httpTransport(self: *DummyTransport) sdk.HttpTransport {
        return .{
            .ptr = self,
            .vtable = &.{ .execute = executeBridge },
        };
    }

    fn executeBridge(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: sdk.HttpMethod,
        _: []const u8,
        _: []const sdk.HttpHeader,
        _: []const u8,
    ) sdk.HttpTransportError!sdk.HttpResponse {
        return .{ .status_code = 200, .body = "{\"access_token\":\"tok123\",\"expires_in\":900}" };
    }
};

test "EnvInterpolator.parseDotEnv expands intra-file variables and preserves single-quoted literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interp = flowdata.yaml.EnvInterpolator.init(false);
    defer interp.deinit(alloc);

    const dotenv =
        \\KOMGA_HOST=192.168.1.50
        \\KOMGA_SSH_HOST=${KOMGA_HOST}
        \\KOMGA_URL="http://${KOMGA_HOST}:${KOMGA_PORT:-25600}"
        \\LITERAL_VAL='${KOMGA_HOST}'
    ;

    try interp.parseDotEnv(alloc, dotenv);

    try std.testing.expectEqualStrings("192.168.1.50", interp.get("KOMGA_HOST").?);
    try std.testing.expectEqualStrings("192.168.1.50", interp.get("KOMGA_SSH_HOST").?);
    try std.testing.expectEqualStrings("http://192.168.1.50:25600", interp.get("KOMGA_URL").?);
    try std.testing.expectEqualStrings("${KOMGA_HOST}", interp.get("LITERAL_VAL").?);
}
