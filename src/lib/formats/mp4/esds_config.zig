/// Decoded MPEG-4 Elementary Stream Descriptor (`esds` box payload).
pub const EsdsConfig = struct {
    es_id: u16 = 0,
    object_type_indication: u8 = 0, // e.g. 0x40 = Audio AAC, 0x20 = Visual MPEG-4
    stream_type: u8 = 0,            // e.g. 0x04 = VisualStream, 0x05 = AudioStream
    buffer_size_db: u24 = 0,
    max_bitrate: u32 = 0,
    avg_bitrate: u32 = 0,
    audio_sample_rate: u32 = 0,
    audio_channels: u8 = 0,
};
