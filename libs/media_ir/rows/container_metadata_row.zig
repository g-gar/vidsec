pub const ContainerMetadataRow = struct {
    file_size: u64,
    detected_format: i64 = 0,
    true_magic: i64 = 0,
    true_magic_name: []const u8 = "unknown",
    highest_root_end: u64 = 0,
};
