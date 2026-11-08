const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("contracts/mod.zig");

pub const InboundTransport = contracts.InboundTransport;
pub const NetworkTimeouts = contracts.NetworkTimeouts;

pub const InboundTransportConfig = struct {
    listen_address: []const u8 = "127.0.0.1:8080",
    max_requests: ?usize = null,
    pipeline_path: []const u8 = "",
    timeouts: NetworkTimeouts = .{},
    args: []const []const u8 = &.{},
};

pub const InboundFactoryFn = *const fn (
    allocator: Allocator,
    config: InboundTransportConfig,
) anyerror!InboundTransport;

/// Central registry mapping transport protocol names ("cli", "http", "grpc") to their daemon/client factories.
/// Populated modularly by inbound transport extensions.
pub const InboundRegistry = struct {
    allocator: Allocator,
    factories: std.StringHashMapUnmanaged(InboundFactoryFn) = .empty,

    pub fn init(allocator: Allocator) InboundRegistry {
        return InboundRegistry{
            .allocator = allocator,
            .factories = .empty,
        };
    }

    pub fn deinit(self: *InboundRegistry) void {
        var it = self.factories.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.factories.deinit(self.allocator);
    }

    pub fn register(self: *InboundRegistry, name: []const u8, factory: InboundFactoryFn) !void {
        if (!self.factories.contains(name)) {
            const owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned);
            try self.factories.put(self.allocator, owned, factory);
        } else {
            try self.factories.put(self.allocator, name, factory);
        }
    }

    /// Backward compatibility hook (transports now register via kernel extensions).
    pub fn registerDefaults(_: *InboundRegistry) !void {}

    pub fn create(self: *const InboundRegistry, name: []const u8, cfg: InboundTransportConfig) !InboundTransport {
        const factory = self.factories.get(name) orelse return error.UnknownInboundTransport;
        return try factory(self.allocator, cfg);
    }
};
