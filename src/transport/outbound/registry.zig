const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("contracts/mod.zig");
const strategies = @import("strategies/mod.zig");
const drivers = @import("drivers/mod.zig");

pub const NetworkAdapter = contracts.NetworkAdapter;
pub const OutboundAdapter = contracts.OutboundAdapter;
pub const NetworkSpec = contracts.NetworkSpec;
pub const AdapterConfig = contracts.AdapterConfig;
pub const ProtocolTransport = contracts.ProtocolTransport;
pub const TransportRegistry = contracts.TransportRegistry;
pub const AdapterDriverContext = drivers.AdapterDriverContext;
pub const AdapterDriverFactoryFn = drivers.AdapterDriverFactoryFn;
pub const MiddlewareFactoryFn = drivers.MiddlewareFactoryFn;
pub const SinkFactoryFn = drivers.SinkFactoryFn;
pub const ProxyStrategyRegistry = strategies.ProxyStrategyRegistry;

/// IoC Registry mapping logical network adapter IDs to polymorphic `OutboundAdapter` instances,
/// and registering open-ended driver factories (`"none"`, `"ingress_only"`, `"egress"`, `"sinkhole"`, etc.),
/// proxy selector strategies, custom URI protocols, extra pipeline middlewares, and packet sinks.
pub const OutboundRegistry = struct {
    allocator: Allocator,
    adapters: std.StringHashMapUnmanaged(NetworkAdapter) = .empty,
    driver_factories: std.StringHashMapUnmanaged(AdapterDriverFactoryFn) = .empty,
    proxy_strategies: ProxyStrategyRegistry,
    base_transports: TransportRegistry,
    extra_middlewares: std.ArrayListUnmanaged(MiddlewareFactoryFn) = .empty,
    extra_sinks: std.ArrayListUnmanaged(SinkFactoryFn) = .empty,

    pub fn init(allocator: Allocator) OutboundRegistry {
        var proxy_reg = ProxyStrategyRegistry.init(allocator) catch unreachable;
        errdefer proxy_reg.deinit();

        var base_t = TransportRegistry.init(allocator);
        errdefer base_t.deinit();

        var reg = OutboundRegistry{
            .allocator = allocator,
            .proxy_strategies = proxy_reg,
            .base_transports = base_t,
        };
        reg.registerDefaultDrivers() catch unreachable;
        return reg;
    }

    pub fn deinit(self: *OutboundRegistry) void {
        var it = self.adapters.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit();
        }
        self.adapters.deinit(self.allocator);

        var dit = self.driver_factories.keyIterator();
        while (dit.next()) |k| {
            self.allocator.free(k.*);
        }
        self.driver_factories.deinit(self.allocator);

        self.extra_middlewares.deinit(self.allocator);
        self.extra_sinks.deinit(self.allocator);
        self.base_transports.deinit();
        self.proxy_strategies.deinit();
    }

    pub fn registerDriver(self: *OutboundRegistry, driver_name: []const u8, factory: AdapterDriverFactoryFn) !void {
        if (!self.driver_factories.contains(driver_name)) {
            const owned = try self.allocator.dupe(u8, driver_name);
            errdefer self.allocator.free(owned);
            try self.driver_factories.put(self.allocator, owned, factory);
        } else {
            try self.driver_factories.put(self.allocator, driver_name, factory);
        }
    }

    pub fn registerDefaultDrivers(self: *OutboundRegistry) !void {
        try self.registerDriver("none", &drivers.IsolatedAdapter.createHeap);
        try self.registerDriver("ingress_only", &drivers.IngressOnlyAdapter.createHeap);
        try self.registerDriver("sinkhole", &drivers.SinkholeAdapter.createHeap);
        try self.registerDriver("egress", &drivers.EgressAdapter.createHeap);
    }

    /// Registers a custom protocol transport (e.g. `s3://`, `customproto://`) available to all outbound adapters.
    pub fn registerProtocol(self: *OutboundRegistry, transport: ProtocolTransport) !void {
        try self.base_transports.registerTransport(transport);
    }

    /// Registers a middleware factory injected into outbound adapter execution chains.
    pub fn registerMiddlewareFactory(self: *OutboundRegistry, factory: MiddlewareFactoryFn) !void {
        try self.extra_middlewares.append(self.allocator, factory);
    }

    /// Registers a packet sink factory injected into outbound capture middleware.
    pub fn registerSinkFactory(self: *OutboundRegistry, factory: SinkFactoryFn) !void {
        try self.extra_sinks.append(self.allocator, factory);
    }

    pub fn register(self: *OutboundRegistry, id: []const u8, adapter: NetworkAdapter) !void {
        if (self.adapters.getPtr(id)) |existing| {
            existing.deinit();
            existing.* = adapter;
            return;
        }
        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try self.adapters.put(self.allocator, owned, adapter);
    }

    pub fn get(self: *const OutboundRegistry, id: []const u8) ?NetworkAdapter {
        return self.adapters.get(id);
    }

    /// Resolves an existing `OutboundAdapter` by ID, or instantiates it using the registered driver factory.
    pub fn resolveOrCreate(self: *OutboundRegistry, spec: NetworkSpec) !NetworkAdapter {
        if (self.get(spec.id)) |existing| {
            return existing;
        }

        const factory = self.driver_factories.get(spec.effectiveDriverName()) orelse return error.UnknownNetworkDriver;
        const ctx = AdapterDriverContext{
            .proxy_strategies = &self.proxy_strategies,
            .base_transports = &self.base_transports,
            .extra_middlewares = self.extra_middlewares.items,
            .extra_sinks = self.extra_sinks.items,
        };
        const adapter = try factory(self.allocator, spec, ctx);
        try self.register(spec.id, adapter);
        return adapter;
    }

    /// Ensures the built-in air-gapped `isolated` (`driver: "none"`) adapter is available.
    pub fn ensureBuiltinIsolated(self: *OutboundRegistry, default_id: []const u8) !NetworkAdapter {
        if (self.get(default_id)) |existing| return existing;
        return try self.resolveOrCreate(.{
            .id = default_id,
            .driver = .none,
        });
    }
};

pub const NetworkRegistry = OutboundRegistry;
