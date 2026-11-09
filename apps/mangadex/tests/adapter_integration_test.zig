const std = @import("std");
const flowdata = @import("flowdata");
const OutboundRegistry = flowdata.transport.outbound.OutboundRegistry;
const OutboundAdapter = flowdata.transport.outbound.OutboundAdapter;
const CustomTransportResult = flowdata.transport.outbound.CustomTransportResult;
const FlowdataHttpAdapter = @import("mangadex_app").adapters.FlowdataHttpAdapter;
const sdk = @import("mangadex_sdk");

fn testTransportMock(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    effective_url: []const u8,
    operation: []const u8,
    _: ?[]const u8,
    body: []const u8,
) anyerror!CustomTransportResult {
    _ = operation;
    _ = body;

    if (std.mem.indexOf(u8, effective_url, "/ping") != null) {
        return .{
            .status_code = 200,
            .body = "pong",
            .latency_ms = 5,
        };
    }

    if (std.mem.indexOf(u8, effective_url, "/rate-limited") != null) {
        return .{
            .status_code = 429,
            .body = "too many requests",
            .retry_after_ms = 5000,
        };
    }

    return .{
        .status_code = 200,
        .body = "{\"result\":\"ok\"}",
        .latency_ms = 1,
    };
}

test "FlowdataHttpAdapter bridges OutboundAdapter to sdk.HttpTransport" {
    const allocator = std.testing.allocator;

    var reg = OutboundRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerDefaultDrivers();

    const adapter = try reg.resolveOrCreate(.{
        .id = "mangadex_egress",
        .driver = .egress,
        .policy = .{
            .default_action = .allow,
            .block_loopback = false,
            .block_private_ips = false,
        },
    });
    adapter.setTransportHandler(null, &testTransportMock);

    var bridge = FlowdataHttpAdapter.init(adapter);
    const transport = bridge.httpTransport();

    // 1. Test standard 200 GET
    const resp1 = try transport.execute(allocator, .GET, "https://api.mangadex.org/ping", &.{}, "");
    try std.testing.expectEqual(@as(u16, 200), resp1.status_code);
    try std.testing.expectEqualStrings("pong", resp1.body);

    // 2. Test rate limiting / 429 propagation
    const resp2 = try transport.execute(allocator, .GET, "https://api.mangadex.org/rate-limited", &.{}, "");
    try std.testing.expectEqual(@as(u16, 429), resp2.status_code);
    try std.testing.expectEqual(@as(u64, 5000), resp2.retry_after_ms);
}

test "FlowdataHttpAdapter maps network error properly" {
    // Test with mock OutboundAdapter VTable returning NetError
    const MockErrAdapter = struct {
        pub fn outboundAdapter(self: *@This()) OutboundAdapter {
            return .{
                .ptr = self,
                .vtable = &.{
                    .execute = executeErr,
                    .connectStream = undefined,
                    .streamSend = undefined,
                    .streamRecv = undefined,
                    .streamClose = undefined,
                    .capturedRecordsSlice = undefined,
                    .pcapBytes = undefined,
                    .metrics = undefined,
                    .advanceClockMs = undefined,
                    .setTransportHandler = undefined,
                    .deinit = deinitNop,
                },
            };
        }

        fn executeErr(
            _: *anyopaque,
            _: []const u8,
            _: []const u8,
            _: []const flowdata.transport.outbound.HttpHeader,
            _: []const u8,
            _: []const u8,
        ) flowdata.transport.outbound.NetError!flowdata.transport.outbound.NetResult {
            return error.NetworkRateLimited;
        }

        fn deinitNop(_: *anyopaque) void {}
    };

    var mock_obj = MockErrAdapter{};
    var bridge = FlowdataHttpAdapter.init(mock_obj.outboundAdapter());
    const transport = bridge.httpTransport();

    const err = transport.execute(std.testing.allocator, .GET, "https://api.mangadex.org/test", &.{}, "");
    try std.testing.expectError(error.RateLimited, err);
}
