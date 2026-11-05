const std = @import("std");
const Allocator = std.mem.Allocator;
const StorageRepository = @import("storage_repository.zig").StorageRepository;
const ast = @import("../ast/ast.zig");

pub const DatasourceFactoryFn = *const fn (
    allocator: Allocator,
    params: []const ast.KeyValueParam,
) anyerror!StorageRepository;

/// IoC Registry mapping logical repository names to StorageRepository instances,
/// and registering open-ended driver factories (memory, sqlite, file_store, elasticsearch, etc.).
pub const RepositoryRegistry = struct {
    allocator: Allocator,
    repositories: std.StringHashMapUnmanaged(StorageRepository) = .empty,
    drivers: std.StringHashMapUnmanaged(DatasourceFactoryFn) = .empty,

    pub fn init(allocator: Allocator) RepositoryRegistry {
        return .{
            .allocator = allocator,
        };
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
        try self.repositories.put(self.allocator, owned_name, repo);
    }

    pub fn registerDriver(self: *RepositoryRegistry, driver_name: []const u8, factory: DatasourceFactoryFn) !void {
        const owned_name = try self.allocator.dupe(u8, driver_name);
        errdefer self.allocator.free(owned_name);
        try self.drivers.put(self.allocator, owned_name, factory);
    }

    pub fn get(self: *const RepositoryRegistry, name: []const u8) ?StorageRepository {
        return self.repositories.get(name);
    }

    /// Resolves an existing repository by ID, or instantiates it using the registered driver factory.
    pub fn resolveOrCreate(self: *RepositoryRegistry, spec: ast.DatasourceSpec) !StorageRepository {
        if (self.get(spec.id)) |existing| {
            return existing;
        }

        const factory = self.drivers.get(spec.driver) orelse return error.UnknownDatasourceDriver;
        const repo = try factory(self.allocator, spec.params);
        try self.register(spec.id, repo);
        return repo;
    }
};
