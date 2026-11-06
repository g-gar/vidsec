pub const storage_repository = @import("storage_repository.zig");
pub const repository_registry = @import("repository_registry.zig");

pub const StorageRepository = storage_repository.StorageRepository;
pub const StorageRepositoryVTable = storage_repository.StorageRepositoryVTable;
pub const RepositoryRegistry = repository_registry.RepositoryRegistry;
pub const DatasourceFactoryFn = repository_registry.DatasourceFactoryFn;

// Convenient re-exports of standard datasource drivers
pub const memory = @import("../extensions/datasources/memory.zig");
pub const file_store = @import("../extensions/datasources/file_store.zig");
pub const sqlite = @import("../extensions/datasources/sqlite.zig");

pub const MemoryRepository = memory.MemoryRepository;
pub const FileStoreRepository = file_store.FileStoreRepository;
pub const SqliteRepository = sqlite.SqliteRepository;
pub const registerDefaultDrivers = @import("../extensions/datasources/mod.zig").registerDefaultDrivers;
