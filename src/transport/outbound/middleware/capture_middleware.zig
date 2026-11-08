const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const NetMiddleware = contracts.NetMiddleware;
const NextHandler = contracts.NextHandler;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const PacketSink = contracts.PacketSink;

/// Composable Telemetry & Packet Capture observer middleware.
/// Wraps downstream execution and fans out completed exchanges (including blocked/rate-limited verdicts)
/// to all registered `PacketSink` VTables.
pub const CaptureMiddleware = struct {
    comptime {
        NetMiddleware.assertImplements(@This());
    }

    sinks: std.ArrayListUnmanaged(PacketSink) = .empty,

    pub fn createHeap(allocator: Allocator, sinks_slice: []const PacketSink) !NetMiddleware {
        const self = try allocator.create(CaptureMiddleware);
        errdefer allocator.destroy(self);
        var list: std.ArrayListUnmanaged(PacketSink) = .empty;
        try list.appendSlice(allocator, sinks_slice);
        self.* = .{ .sinks = list };
        return self.netMiddleware();
    }

    pub fn intercept(self: *CaptureMiddleware, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
        if (next_handler.next(exchange)) |res| {
            for (self.sinks.items) |sink| {
                sink.onExchange(exchange, &res) catch return error.OutOfMemory;
            }
            return res;
        } else |err| {
            const synthetic_res: NetResult = switch (err) {
                error.NetworkPolicyDenied => .{
                    .status_code = 0,
                    .body = "",
                    .effective_url = exchange.effective_url,
                    .proxy_used = exchange.selected_proxy_url,
                    .latency_ms = 0,
                    .verdict = .blocked,
                },
                error.NetworkRateLimited, error.NetworkAcquireTimeout => .{
                    .status_code = 429,
                    .body = "",
                    .effective_url = exchange.effective_url,
                    .proxy_used = exchange.selected_proxy_url,
                    .latency_ms = 0,
                    .verdict = .rate_limited,
                },
                else => return err,
            };

            for (self.sinks.items) |sink| {
                sink.onExchange(exchange, &synthetic_res) catch return error.OutOfMemory;
            }
            return err;
        }
    }

    pub fn netMiddleware(self: *CaptureMiddleware) NetMiddleware {
        const Trampoline = struct {
            fn doIntercept(ctx: *anyopaque, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
                const s: *CaptureMiddleware = @ptrCast(@alignCast(ctx));
                return try s.intercept(exchange, next_handler);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *CaptureMiddleware = @ptrCast(@alignCast(ctx));
                s.sinks.deinit(allocator);
                allocator.destroy(s);
            }

            const vtable = NetMiddleware.VTable{
                .intercept = &doIntercept,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
