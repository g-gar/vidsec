pub const memory = @import("memory.zig");
pub const file_store = @import("file_store.zig");
pub const sqlite = @import("sqlite.zig");

pub const MemoryRepository = memory.MemoryRepository;
pub const FileStoreRepository = file_store.FileStoreRepository;
pub const SqliteRepository = sqlite.SqliteRepository;

pub fn registerDefaultDrivers(registry: anytype) !void {
    try registry.registerDriver("memory", &memory.MemoryRepository.createHeap);
    try registry.registerDriver("file_store", &file_store.FileStoreRepository.createHeap);
}
