pub const IrCodecConfigRow = struct {
    config_id: i64,
    track_id: i64,
    codec_tag: []const u8,
    container_width: i64,
    container_height: i64,
    bitstream_width: i64,
    bitstream_height: i64,
    is_mismatch: bool,
};
