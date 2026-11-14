const std = @import("std");
const Allocator = std.mem.Allocator;
const StorageRepository = @import("storage_repository.zig").StorageRepository;
const concurrency_policy = @import("concurrency_policy.zig");
pub const ConcurrencyPolicy = concurrency_policy.ConcurrencyPolicy;
pub const ManagedRepository = concurrency_policy.ManagedRepository;

/// Generic key-value configuration parameter for initializing storage datasources.
pub const ConfigParam = @import("storage_repository.zig").ConfigParam;

/// Open-ended datasource configuration specification.
pub const DatasourceConfig = struct {
    id: []const u8,
    driver: []const u8,
    params: []const ConfigParam = &.{},
};

pub const DatasourceFactoryFn = *const fn (
    allocator: Allocator,
    params: []const ConfigParam,
) anyerror!StorageRepository;

/// IoC Registry mapping logical repository names to StorageRepository instances,
/// and registering open-ended driver factories (memory, sqlite, file_store, elasticsearch, etc.).
pub const RepositoryRegistry = struct {
    allocator: Allocator,
    repositories: std.StringHashMapUnmanaged(ManagedRepository) = .empty,
    drivers: std.StringHashMapUnmanaged(DatasourceFactoryFn) = .empty,
    default_concurrency: ConcurrencyPolicy = .none,

    pub fn init(allocator: Allocator) RepositoryRegistry {
        return .{
            .allocator = allocator,
        };
    }

    pub fn setConcurrencyPolicy(self: *RepositoryRegistry, policy: ConcurrencyPolicy) void {
        self.default_concurrency = policy;
    }

    pub fn deinit(self: *RepositoryRegistry) void {
        var iter = self.repositories.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.repositories.deinit(self.allocator);

        var d_iter = self.drivers.iterator();
        while (d_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.drivers.deinit(self.allocator);
    }

    pub fn register(self: *RepositoryRegistry, name: []const u8, repo: StorageRepository) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.repositories.put(self.allocator, owned_name, .{ .none = repo });
    }

    pub fn registerDriver(self: *RepositoryRegistry, driver_name: []const u8, factory: DatasourceFactoryFn) !void {
        const owned_name = try self.allocator.dupe(u8, driver_name);
        errdefer self.allocator.free(owned_name);
        try self.drivers.put(self.allocator, owned_name, factory);
    }

    pub fn get(self: *const RepositoryRegistry, name: []const u8) ?StorageRepository {
        if (self.repositories.get(name)) |managed| {
            return managed.repository();
        }
        return null;
    }

    /// Resolves an existing repository by ID, or instantiates it using the registered driver factory,
    /// wrapping it according to `default_concurrency`.
    pub fn resolveOrCreate(self: *RepositoryRegistry, spec: anytype) !StorageRepository {
        if (self.get(spec.id)) |existing| {
            return existing;
        }

        const factory = self.drivers.get(spec.driver) orelse return error.UnknownDatasourceDriver;
        const raw_repo = try factory(self.allocator, spec.params);
        var managed = ManagedRepository.init(self.allocator, raw_repo, self.default_concurrency) catch |err| {
            raw_repo.deinit();
            return err;
        };
        errdefer managed.deinit();

        const owned_name = try self.allocator.dupe(u8, spec.id);
        errdefer self.allocator.free(owned_name);
        try self.repositories.put(self.allocator, owned_name, managed);
        return managed.repository();
    }
};
