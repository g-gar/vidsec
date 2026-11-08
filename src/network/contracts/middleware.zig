const std = @import("std");
const Allocator = std.mem.Allocator;
const exchange_mod = @import("exchange.zig");
const transport_mod = @import("transport.zig");

pub const NetExchange = exchange_mod.NetExchange;
pub const NetResult = exchange_mod.NetResult;
pub const NetError = exchange_mod.NetError;
pub const TransportDispatcher = transport_mod.TransportDispatcher;

/// Continuation handle passed to each `NetMiddleware` in the chain.
pub const NextHandler = struct {
    middlewares: []const NetMiddleware,
    index: usize,
    dispatcher: TransportDispatcher,

    pub fn next(self: NextHandler, exchange: *NetExchange) NetError!NetResult {
        if (self.index < self.middlewares.len) {
            const current = self.middlewares[self.index];
            const following = NextHandler{
                .middlewares = self.middlewares,
                .index = self.index + 1,
                .dispatcher = self.dispatcher,
            };
            return try current.intercept(exchange, following);
        }
        return try self.dispatcher.dispatch(exchange);
    }
};

/// Polymorphic VTable interface for composable network interceptors / middlewares.
/// Each Lego stage (Redirect, DNS, PolicyGuard, RateLimit, ProxyRouter, PacketCapture) implements this interface.
pub const NetMiddleware = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        intercept: *const fn (ctx: *anyopaque, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult,
        deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub fn intercept(self: NetMiddleware, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
        return try self.vtable.intercept(self.ptr, exchange, next_handler);
    }

    pub fn deinit(self: NetMiddleware, allocator: Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "netMiddleware")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn netMiddleware(*" ++ @typeName(T) ++ ") NetMiddleware'");
            }
        }
    }
};

/// Ordered pipeline of `NetMiddleware` stages terminating at a `TransportDispatcher`.
pub const MiddlewareChain = struct {
    allocator: Allocator,
    stages: std.ArrayListUnmanaged(NetMiddleware) = .empty,

    pub fn init(allocator: Allocator) MiddlewareChain {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MiddlewareChain) void {
        for (self.stages.items) |stage| {
            stage.deinit(self.allocator);
        }
        self.stages.deinit(self.allocator);
    }

    pub fn use(self: *MiddlewareChain, mw: NetMiddleware) !void {
        try self.stages.append(self.allocator, mw);
    }

    pub fn execute(self: *const MiddlewareChain, exchange: *NetExchange, dispatcher: TransportDispatcher) NetError!NetResult {
        const root = NextHandler{
            .middlewares = self.stages.items,
            .index = 0,
            .dispatcher = dispatcher,
        };
        return try root.next(exchange);
    }
};
