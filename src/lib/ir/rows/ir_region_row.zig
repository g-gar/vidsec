pub const IrRegionRow = struct {
    region_id: i64,
    parent_region_id: ?i64 = null,
    tag_name: []const u8,
    role: []const u8 = "unknown",
    header_offset: u64,
    payload_offset: u64,
    effective_end_offset: u64,
    is_truncated_or_overflow: bool = false,
};
