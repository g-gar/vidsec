const flowdata = @import("flowdata");
pub const memory = @import("flowdata_datasource_memory");
pub const file_store = @import("flowdata_datasource_file_store");
pub const sqlite = @import("flowdata_datasource_sqlite");
pub const yaml_file = @import("flowdata_datasource_yaml_file");
pub const ssh_store = @import("flowdata_datasource_ssh_store");

pub const MemoryRepository = memory.MemoryRepository;
pub const FileStoreRepository = file_store.FileStoreRepository;
pub const SqliteRepository = sqlite.SqliteRepository;
pub const YamlFileRepository = yaml_file.YamlFileRepository;
pub const SshStoreRepository = ssh_store.SshStoreRepository;

pub fn registerDefaultDrivers(registry: *flowdata.repository.RepositoryRegistry) !void {
    try registry.registerDriver("memory", &memory.MemoryRepository.createHeap);
    try registry.registerDriver("file_store", &file_store.FileStoreRepository.createHeap);
    try registry.registerDriver("sqlite", &sqlite.SqliteRepository.createHeap);
    try registry.registerDriver("yaml_file", &yaml_file.YamlFileRepository.createHeap);
    try registry.registerDriver("yaml", &yaml_file.YamlFileRepository.createHeap);
    try registry.registerDriver("ssh_store", &ssh_store.SshStoreRepository.createHeap);
}

pub const extension = flowdata.kernel.Extension.fromStateless(
    "flowdata.datasources.default",
    &registerExtension,
);

pub fn registerExtension(kernel: *flowdata.kernel.KernelContext) anyerror!void {
    try registerDefaultDrivers(&kernel.datasources);
}
