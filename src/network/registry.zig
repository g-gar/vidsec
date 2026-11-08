const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("contracts/mod.zig");
const strategies = @import("strategies/mod.zig");
const drivers = @import("drivers/mod.zig");

pub const NetworkAdapter = contracts.NetworkAdapter;
pub const NetworkSpec = contracts.NetworkSpec;
pub const AdapterConfig = contracts.AdapterConfig;
pub const AdapterDriverFactoryFn = drivers.AdapterDriverFactoryFn;
pub const ProxyStrategyRegistry = strategies.ProxyStrategyRegistry;

/// IoC Registry mapping logical network adapter IDs to polymorphic `NetworkAdapter` instances,
/// and registering open-ended driver factories (`"none"`, `"ingress_only"`, `"egress"`, `"sinkhole"`, etc.)
/// and proxy selector strategies.
/// Follows the exact pattern of `RepositoryRegistry` with zero translation boilerplate.
pub const NetworkRegistry = struct {
    allocator: Allocator,
    adapters: std.StringHashMapUnmanaged(NetworkAdapter) = .empty,
    driver_factories: std.StringHashMapUnmanaged(AdapterDriverFactoryFn) = .empty,
    proxy_strategies: ProxyStrategyRegistry,

    pub fn init(allocator: Allocator) NetworkRegistry {
        var proxy_reg = ProxyStrategyRegistry.init(allocator) catch unreachable;
        errdefer proxy_reg.deinit();

        var reg = NetworkRegistry{
            .allocator = allocator,
            .proxy_strategies = proxy_reg,
        };
        reg.registerDefaultDrivers() catch unreachable;
        return reg;
    }

    pub fn deinit(self: *NetworkRegistry) void {
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

        self.proxy_strategies.deinit();
    }

    pub fn registerDriver(self: *NetworkRegistry, driver_name: []const u8, factory: AdapterDriverFactoryFn) !void {
        if (!self.driver_factories.contains(driver_name)) {
            const owned = try self.allocator.dupe(u8, driver_name);
            errdefer self.allocator.free(owned);
            try self.driver_factories.put(self.allocator, owned, factory);
        } else {
            try self.driver_factories.put(self.allocator, driver_name, factory);
        }
    }

    pub fn registerDefaultDrivers(self: *NetworkRegistry) !void {
        try self.registerDriver("none", &drivers.IsolatedAdapter.createHeap);
        try self.registerDriver("ingress_only", &drivers.IngressOnlyAdapter.createHeap);
        try self.registerDriver("sinkhole", &drivers.SinkholeAdapter.createHeap);
        try self.registerDriver("egress", &drivers.EgressAdapter.createHeap);
    }

    pub fn register(self: *NetworkRegistry, id: []const u8, adapter: NetworkAdapter) !void {
        if (self.adapters.getPtr(id)) |existing| {
            existing.deinit();
            existing.* = adapter;
            return;
        }
        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try self.adapters.put(self.allocator, owned, adapter);
    }

    pub fn get(self: *const NetworkRegistry, id: []const u8) ?NetworkAdapter {
        return self.adapters.get(id);
    }

    /// Resolves an existing `NetworkAdapter` by ID, or instantiates it using the registered driver factory.
    pub fn resolveOrCreate(self: *NetworkRegistry, spec: NetworkSpec) !NetworkAdapter {
        if (self.get(spec.id)) |existing| {
            return existing;
        }

        const factory = self.driver_factories.get(spec.effectiveDriverName()) orelse return error.UnknownNetworkDriver;
        const adapter = try factory(self.allocator, spec, &self.proxy_strategies);
        try self.register(spec.id, adapter);
        return adapter;
    }

    /// Ensures the built-in air-gapped `isolated` (`driver: "none"`) adapter is available.
    pub fn ensureBuiltinIsolated(self: *NetworkRegistry, default_id: []const u8) !NetworkAdapter {
        if (self.get(default_id)) |existing| return existing;
        return try self.resolveOrCreate(.{
            .id = default_id,
            .driver = .none,
        });
    }
};
