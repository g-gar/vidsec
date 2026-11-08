const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const NetMiddleware = contracts.NetMiddleware;
const NextHandler = contracts.NextHandler;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const DnsResolver = contracts.DnsResolver;

/// Composable interceptor that resolves `exchange.uri.host` via an injected `DnsResolver` VTable
/// before policy and transport evaluation.
pub const DnsMiddleware = struct {
    comptime {
        NetMiddleware.assertImplements(@This());
    }

    resolver: DnsResolver,

    pub fn createHeap(allocator: Allocator, resolver: DnsResolver) !NetMiddleware {
        const self = try allocator.create(DnsMiddleware);
        self.* = .{ .resolver = resolver };
        return self.netMiddleware();
    }

    pub fn intercept(self: *DnsMiddleware, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
        const res = self.resolver.resolve(exchange.uri.host, exchange.now_ms);
        exchange.resolved_ip = res.ip_address;
        exchange.metrics.dns_cache_hits = self.resolver.hits();
        exchange.metrics.dns_cache_misses = self.resolver.misses();
        return try next_handler.next(exchange);
    }

    pub fn netMiddleware(self: *DnsMiddleware) NetMiddleware {
        const Trampoline = struct {
            fn doIntercept(ctx: *anyopaque, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
                const s: *DnsMiddleware = @ptrCast(@alignCast(ctx));
                return try s.intercept(exchange, next_handler);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *DnsMiddleware = @ptrCast(@alignCast(ctx));
                s.resolver.deinit(allocator);
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
