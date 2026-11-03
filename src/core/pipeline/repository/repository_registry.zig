const std = @import("std");
const Allocator = std.mem.Allocator;
const StorageRepository = @import("storage_repository.zig").StorageRepository;

/// IoC Registry mapping repository names ("memory", "sqlite", etc.) to StorageRepository instances.
pub const RepositoryRegistry = struct {
    allocator: Allocator,
    repositories: std.StringHashMapUnmanaged(StorageRepository) = .empty,

    pub fn init(allocator: Allocator) RepositoryRegistry {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RepositoryRegistry) void {
        var iter = self.repositories.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.repositories.deinit(self.allocator);
    }

    pub fn register(self: *RepositoryRegistry, name: []const u8, repo: StorageRepository) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.repositories.put(self.allocator, owned_name, repo);
    }

    pub fn get(self: *const RepositoryRegistry, name: []const u8) ?StorageRepository {
        return self.repositories.get(name);
    }
};
