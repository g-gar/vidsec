pub const MkvAvcConfig = struct {
    profile: u8,
    level: u8,
    sps_count: u8,
    pps_count: u8,
    sps_bytes_total: u32,
    pps_bytes_total: u32,
};
