pub const IrSampleExtentRow = struct {
    extent_id: i64,
    track_id: i64,
    sample_index: i64,
    source_tag: []const u8,
    target_offset: u64,
    byte_size: u64,
    end_offset: u64,
};
