const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const ProtocolTransport = contracts.ProtocolTransport;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const TransportDispatcher = contracts.TransportDispatcher;

/// Offline synthetic loopback transport used by `SinkholeAdapter` (`driver: sinkhole`).
/// Implements the polymorphic `ProtocolTransport` VTable.
pub const MockSinkholeTransport = struct {
    comptime {
        ProtocolTransport.assertImplements(@This());
    }

    pub const supported_schemes = [_][]const u8{
        "http", "https", "ws", "wss", "grpc", "grpcs", "rtmp", "rtmps", "rtsp", "amqp", "tcp", "udp", "tls", "quic",
    };

    emulate_responses: bool = true,

    pub fn roundTrip(self: *MockSinkholeTransport, exchange: *NetExchange) NetError!NetResult {
        if (self.emulate_responses) {
            return .{
                .status_code = 200,
                .body = "{\"status\":\"mocked_by_sinkhole\"}",
                .effective_url = exchange.effective_url,
                .proxy_used = "",
                .latency_ms = 1,
                .verdict = .mocked,
            };
        }
        return .{
            .status_code = 0,
            .body = "",
            .effective_url = exchange.effective_url,
            .proxy_used = "",
            .latency_ms = 1,
            .verdict = .captured,
        };
    }

    pub fn dispatcher(self: *MockSinkholeTransport) TransportDispatcher {
        const Trampoline = struct {
            fn doDispatch(ctx: *anyopaque, exchange: *NetExchange) NetError!NetResult {
                const s: *MockSinkholeTransport = @ptrCast(@alignCast(ctx));
                return try s.roundTrip(exchange);
            }
        };
        return .{
            .ptr = self,
            .dispatch_fn = &Trampoline.doDispatch,
        };
    }

    pub fn protocolTransport(self: *MockSinkholeTransport) ProtocolTransport {
        const Trampoline = struct {
            fn doSchemes(_: *const anyopaque) []const []const u8 {
                return &supported_schemes;
            }

            fn doRoundTrip(ctx: *anyopaque, exchange: *NetExchange) NetError!NetResult {
                const s: *MockSinkholeTransport = @ptrCast(@alignCast(ctx));
                return try s.roundTrip(exchange);
            }

            fn doDeinit(_: *anyopaque, _: Allocator) void {}

            const vtable = ProtocolTransport.VTable{
                .schemes = &doSchemes,
                .roundTrip = &doRoundTrip,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
