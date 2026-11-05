const std = @import("std");

pub const storage_repository = @import("storage_repository.zig");
pub const memory_repository = @import("memory_repository.zig");
pub const sqlite_repository = @import("sqlite_repository.zig");
pub const file_store_repository = @import("file_store_repository.zig");
pub const repository_registry = @import("repository_registry.zig");

pub const StorageRepository = storage_repository.StorageRepository;
pub const MemoryRepository = memory_repository.MemoryRepository;
pub const SqliteRepository = sqlite_repository.SqliteRepository;
pub const FileStoreRepository = file_store_repository.FileStoreRepository;
pub const RepositoryRegistry = repository_registry.RepositoryRegistry;
pub const DatasourceFactoryFn = repository_registry.DatasourceFactoryFn;

test {
    std.testing.refAllDecls(@This());
}
