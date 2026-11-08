const std = @import("std");
const Allocator = std.mem.Allocator;
const exchange_mod = @import("exchange.zig");
const NetExchange = exchange_mod.NetExchange;
const NetResult = exchange_mod.NetResult;
const NetError = exchange_mod.NetError;

/// Optional user-supplied transport callback for test/custom overrides.
pub const CustomTransportResult = struct {
    status_code: u16 = 200,
    body: []const u8 = "",
    latency_ms: u64 = 1,
    retry_after_ms: u64 = 0,
};

pub const CustomTransportFn = *const fn (
    userdata: ?*anyopaque,
    allocator: Allocator,
    effective_url: []const u8,
    operation: []const u8,
    proxy_url: ?[]const u8,
    body: []const u8,
) anyerror!CustomTransportResult;

/// Polymorphic VTable interface for protocol-specific transport engines (`http/s`, `ws/s`, `grpc/s`, `rtmp/s`, `tcp`, `udp`).
/// Eliminates protocol `if/switch` branching by dispatching via `TransportRegistry` by URI scheme.
pub const ProtocolTransport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        schemes: *const fn (ctx: *const anyopaque) []const []const u8,
        roundTrip: *const fn (ctx: *anyopaque, exchange: *NetExchange) NetError!NetResult,
        deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub fn schemes(self: ProtocolTransport) []const []const u8 {
        return self.vtable.schemes(self.ptr);
    }

    pub fn roundTrip(self: ProtocolTransport, exchange: *NetExchange) NetError!NetResult {
        return try self.vtable.roundTrip(self.ptr, exchange);
    }

    pub fn deinit(self: ProtocolTransport, allocator: Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "protocolTransport")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn protocolTransport(*" ++ @typeName(T) ++ ") ProtocolTransport'");
            }
        }
    }
};

/// Terminal dispatcher at the end of a `MiddlewareChain` that resolves the `ProtocolTransport` for `exchange.uri.scheme`.
pub const TransportDispatcher = struct {
    ptr: *anyopaque,
    dispatch_fn: *const fn (ctx: *anyopaque, exchange: *NetExchange) NetError!NetResult,

    pub fn dispatch(self: TransportDispatcher, exchange: *NetExchange) NetError!NetResult {
        return try self.dispatch_fn(self.ptr, exchange);
    }
};

/// Registry mapping RFC 3986 URI schemes (`"http"`, `"https"`, `"ws"`, `"wss"`, `"grpc"`, `"rtmp"`, `"tcp"`, `"udp"`)
/// to their corresponding `ProtocolTransport` implementation.
pub const TransportRegistry = struct {
    allocator: Allocator,
    scheme_map: std.StringHashMapUnmanaged(ProtocolTransport) = .empty,
    owned_transports: std.ArrayListUnmanaged(ProtocolTransport) = .empty,
    custom_userdata: ?*anyopaque = null,
    custom_fn: ?CustomTransportFn = null,

    pub fn init(allocator: Allocator) TransportRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TransportRegistry) void {
        var it = self.scheme_map.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.scheme_map.deinit(self.allocator);

        for (self.owned_transports.items) |t| {
            t.deinit(self.allocator);
        }
        self.owned_transports.deinit(self.allocator);
    }

    pub fn registerTransport(self: *TransportRegistry, transport: ProtocolTransport) !void {
        try self.owned_transports.append(self.allocator, transport);
        for (transport.schemes()) |sc| {
            var lower_buf: [32]u8 = undefined;
            const len = @min(sc.len, lower_buf.len);
            for (sc[0..len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
            const lower_key = lower_buf[0..len];

            if (!self.scheme_map.contains(lower_key)) {
                const duped = try self.allocator.dupe(u8, lower_key);
                errdefer self.allocator.free(duped);
                try self.scheme_map.put(self.allocator, duped, transport);
            } else {
                try self.scheme_map.put(self.allocator, lower_key, transport);
            }
        }
    }

    pub fn setCustomOverride(self: *TransportRegistry, userdata: ?*anyopaque, handler: CustomTransportFn) void {
        self.custom_userdata = userdata;
        self.custom_fn = handler;
    }

    pub fn resolveScheme(self: *const TransportRegistry, scheme: []const u8) ?ProtocolTransport {
        var lower_buf: [32]u8 = undefined;
        const len = @min(scheme.len, lower_buf.len);
        for (scheme[0..len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        return self.scheme_map.get(lower_buf[0..len]);
    }

    pub fn dispatcher(self: *TransportRegistry) TransportDispatcher {
        const Trampoline = struct {
            fn doDispatch(ctx: *anyopaque, exchange: *NetExchange) NetError!NetResult {
                const reg: *TransportRegistry = @ptrCast(@alignCast(ctx));
                if (reg.custom_fn) |cfn| {
                    const proxy_opt: ?[]const u8 = if (exchange.selected_proxy_url.len > 0) exchange.selected_proxy_url else null;
                    const res = cfn(
                        reg.custom_userdata,
                        exchange.allocator,
                        exchange.effective_url,
                        exchange.operation,
                        proxy_opt,
                        exchange.req_body,
                    ) catch return error.NetworkUpstreamError;
                    return .{
                        .status_code = res.status_code,
                        .body = res.body,
                        .effective_url = exchange.effective_url,
                        .proxy_used = exchange.selected_proxy_url,
                        .latency_ms = res.latency_ms,
                        .retry_after_ms = res.retry_after_ms,
                        .verdict = .allowed,
                    };
                }
                const transport = reg.resolveScheme(exchange.uri.scheme) orelse return error.UnsupportedProtocolScheme;
                return try transport.roundTrip(exchange);
            }
        };
        return .{
            .ptr = self,
            .dispatch_fn = &Trampoline.doDispatch,
        };
    }
};
