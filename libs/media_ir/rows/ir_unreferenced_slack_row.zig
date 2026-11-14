pub const IrUnreferencedSlackRow = struct {
    slack_id: i64,
    region_tag: []const u8,
    file_offset: u64,
    byte_length: u64,
};
