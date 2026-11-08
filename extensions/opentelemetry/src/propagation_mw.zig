const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const contracts = flowdata.transport.outbound.contracts;
const NetMiddleware = contracts.NetMiddleware;
const NextHandler = contracts.NextHandler;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const span_mod = @import("span.zig");
const metrics_mod = @import("metrics.zig");

var otel_prng: ?std.Random.DefaultPrng = null;

fn fillBytes(buf: []u8) void {
    if (otel_prng == null) {
        otel_prng = std.Random.DefaultPrng.init(0xfeedface_12345678);
    }
    otel_prng.?.random().bytes(buf);
}

pub const OtelTracePropagationMiddleware = struct {
    comptime {
        NetMiddleware.assertImplements(@This());
    }

    metrics: *metrics_mod.OtelMetricsRegistry,

    pub fn createHeap(allocator: Allocator, metrics: *metrics_mod.OtelMetricsRegistry) !NetMiddleware {
        const self = try allocator.create(OtelTracePropagationMiddleware);
        self.* = .{ .metrics = metrics };
        return self.netMiddleware();
    }

    pub fn intercept(self: *OtelTracePropagationMiddleware, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
        // 1. Inbound trace context propagation or synthesis
        var span_id: [8]u8 = undefined;
        fillBytes(&span_id);

        var trace_id: [16]u8 = undefined;
        if (exchange.trace_tag.len >= 32) {
            _ = std.fmt.hexToBytes(&trace_id, exchange.trace_tag[0..32]) catch {
                fillBytes(&trace_id);
            };
        } else {
            fillBytes(&trace_id);
        }

        const span = span_mod.OtelSpan{
            .trace_id = trace_id,
            .span_id = span_id,
            .name = exchange.operation,
            .kind = .client,
            .start_time_unix_nano = 0,
            .end_time_unix_nano = 0,
        };
        const tp = span.formatTraceparent();

        // Inject into exchange trace tag for downstream inspection
        const original_tag = exchange.trace_tag;
        var tag_buf: [128]u8 = undefined;
        const formatted_tag = std.fmt.bufPrint(&tag_buf, "traceparent={s} orig={s}", .{ tp, original_tag }) catch &tp;
        exchange.trace_tag = formatted_tag;

        if (next_handler.next(exchange)) |res| {
            self.metrics.recordOutbound(false);
            return res;
        } else |err| {
            self.metrics.recordOutbound(true);
            return err;
        }
    }

    pub fn netMiddleware(self: *OtelTracePropagationMiddleware) NetMiddleware {
        const Trampoline = struct {
            fn doIntercept(ctx: *anyopaque, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
                const s: *OtelTracePropagationMiddleware = @ptrCast(@alignCast(ctx));
                return s.intercept(exchange, next_handler);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *OtelTracePropagationMiddleware = @ptrCast(@alignCast(ctx));
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
