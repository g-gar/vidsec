/// Decoded H.264 / AVC configuration record (`avcC` box payload).
pub const AvcCConfig = struct {
    configuration_version: u8,
    profile_indication: u8,
    profile_compatibility: u8,
    level_indication: u8,
    length_size_minus_one: u2, // NAL unit size length in bytes: (val + 1) -> 1, 2, or 4
    sps_count: u8,
    pps_count: u8,
    sps_bytes_total: u32,
    pps_bytes_total: u32,
};
