const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("contracts/mod.zig");
const drivers = @import("drivers/mod.zig");

pub const InboundTransport = contracts.InboundTransport;

pub const InboundTransportConfig = struct {
    listen_address: []const u8 = "127.0.0.1:8080",
    max_requests: ?usize = null,
    pipeline_path: []const u8 = "",
};

pub const InboundFactoryFn = *const fn (
    allocator: Allocator,
    config: InboundTransportConfig,
) anyerror!InboundTransport;

pub const InboundRegistry = struct {
    allocator: Allocator,
    factories: std.StringHashMapUnmanaged(InboundFactoryFn) = .empty,

    pub fn init(allocator: Allocator) !InboundRegistry {
        var reg = InboundRegistry{
            .allocator = allocator,
        };
        try reg.registerDefaults();
        return reg;
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

    pub fn registerDefaults(self: *InboundRegistry) !void {
        try self.register("http", &drivers.HttpTransport.createDaemon);
        try self.register("grpc", &drivers.GrpcTransport.createDaemon);
    }

    pub fn create(self: *const InboundRegistry, name: []const u8, cfg: InboundTransportConfig) !InboundTransport {
        const factory = self.factories.get(name) orelse return error.UnknownInboundTransport;
        return try factory(self.allocator, cfg);
    }
};
