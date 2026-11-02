const std = @import("std");
const isobmff = @import("vidsec_isobmff");

pub const FourCC = isobmff.FourCC;
pub const ParsedBox = isobmff.ParsedBox;
pub const BoxHeader = isobmff.BoxHeader;
pub const FullBoxHeader = isobmff.FullBoxHeader;
pub const ByteSource = isobmff.ByteSource;

// Commonly used MP4 brand FourCCs
pub const BRAND_ISOM = FourCC.init("isom");
pub const BRAND_ISO2 = FourCC.init("iso2");
pub const BRAND_MP41 = FourCC.init("mp41");
pub const BRAND_MP42 = FourCC.init("mp42");
pub const BRAND_AVC1 = FourCC.init("avc1");
pub const BRAND_DASH = FourCC.init("dash");
pub const BRAND_M4A  = FourCC.init("M4A ");
pub const BRAND_M4V  = FourCC.init("M4V ");
pub const BRAND_QT   = FourCC.init("qt  ");

// Handler types in `hdlr`
pub const HANDLER_VIDE = FourCC.init("vide");
pub const HANDLER_SOUN = FourCC.init("soun");
pub const HANDLER_HINT = FourCC.init("hint");
pub const HANDLER_META = FourCC.init("meta");
pub const HANDLER_SUBT = FourCC.init("subt");
pub const HANDLER_TX3G = FourCC.init("tx3g");

// Codec FourCCs in sample entry boxes
pub const CODEC_AVC1 = FourCC.init("avc1");
pub const CODEC_AVC3 = FourCC.init("avc3");
pub const CODEC_HVC1 = FourCC.init("hvc1");
pub const CODEC_HEV1 = FourCC.init("hev1");
pub const CODEC_MP4A = FourCC.init("mp4a");
pub const CODEC_MP4V = FourCC.init("mp4v");
pub const CODEC_AC3  = FourCC.init("ac-3");
pub const CODEC_EAC3 = FourCC.init("ec-3");
pub const CODEC_OPUS = FourCC.init("Opus");
pub const CODEC_VP09 = FourCC.init("vp09");
pub const CODEC_AV01 = FourCC.init("av01");
pub const CODEC_NONE = FourCC.init("none");

// Special box FourCCs specific to MPEG-4
pub const BOX_AVCC = FourCC.init("avcC");
pub const BOX_HVCC = FourCC.init("hvcC");
pub const BOX_ESDS = FourCC.init("esds");
pub const BOX_PASP = FourCC.init("pasp");
pub const BOX_COLR = FourCC.init("colr");

/// Decoded parameters of the `ftyp` (File Type Box).
pub const FtypInfo = struct {
    major_brand: FourCC,
    minor_version: u32,
    compatible_brands: []const FourCC,

    pub fn hasBrand(self: FtypInfo, brand: FourCC) bool {
        if (self.major_brand.equals(brand)) return true;
        for (self.compatible_brands) |cb| {
            if (cb.equals(brand)) return true;
        }
        return false;
    }
};

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

/// Expanded track representation combining `tkhd`, `mdhd`, `hdlr`, and `stbl` sample tables.
pub const TrackInfo = struct {
    track_id: u32,
    handler_type: FourCC,
    codec_fourcc: FourCC,
    width: u32 = 0,          // From `tkhd` fixed-point 16.16 or visual sample entry
    height: u32 = 0,         // From `tkhd` fixed-point 16.16 or visual sample entry
    duration: u64 = 0,       // Duration in timescale units
    timescale: u32 = 0,      // Timescale from `mdhd`
    sample_count: u32 = 0,   // Total samples declared in `stsz`
    chunk_count: u32 = 0,    // Total chunks declared in `stco` / `co64`
    total_sample_bytes: u64 = 0, // Sum of all sample sizes
    avcc: ?AvcCConfig = null,
    esds: ?EsdsConfig = null,

    pub fn isVideo(self: TrackInfo) bool {
        return self.handler_type.equals(HANDLER_VIDE);
    }

    pub fn isAudio(self: TrackInfo) bool {
        return self.handler_type.equals(HANDLER_SOUN);
    }
};

/// Canonical integrity and evasion issue codes specific to MP4 files.
pub const Mp4IssueCode = enum(u8) {
    ftyp_unrecognized_brand = 0,
    ftyp_truncated = 1,
    esds_tlv_length_overflow = 2,
    esds_truncated = 3,
    avcc_invalid_version = 4,
    avcc_sps_length_overflow = 5,
    avcc_pps_length_overflow = 6,
    stco_chunk_offset_out_of_bounds = 7,
    stsz_sample_extends_past_eof = 8,
    track_id_duplicate = 9,
    track_id_zero = 10,
    track_missing_tkhd = 11,
    track_missing_mdhd = 12,
    track_missing_stbl = 13,
    unreferenced_mdat_slack = 14,
    moov_duration_mismatch = 15,

    pub fn asText(self: Mp4IssueCode) []const u8 {
        return switch (self) {
            .ftyp_unrecognized_brand => "MP4_FTYP_UNRECOGNIZED_BRAND",
            .ftyp_truncated => "MP4_FTYP_TRUNCATED",
            .esds_tlv_length_overflow => "MP4_ESDS_TLV_LENGTH_OVERFLOW",
            .esds_truncated => "MP4_ESDS_TRUNCATED",
            .avcc_invalid_version => "MP4_AVCC_INVALID_VERSION",
            .avcc_sps_length_overflow => "MP4_AVCC_SPS_LENGTH_OVERFLOW",
            .avcc_pps_length_overflow => "MP4_AVCC_PPS_LENGTH_OVERFLOW",
            .stco_chunk_offset_out_of_bounds => "MP4_STCO_CHUNK_OFFSET_OUT_OF_BOUNDS",
            .stsz_sample_extends_past_eof => "MP4_STSZ_SAMPLE_EXTENDS_PAST_EOF",
            .track_id_duplicate => "MP4_TRACK_ID_DUPLICATE",
            .track_id_zero => "MP4_TRACK_ID_ZERO",
            .track_missing_tkhd => "MP4_TRACK_MISSING_TKHD",
            .track_missing_mdhd => "MP4_TRACK_MISSING_MDHD",
            .track_missing_stbl => "MP4_TRACK_MISSING_STBL",
            .unreferenced_mdat_slack => "MP4_UNREFERENCED_MDAT_SLACK",
            .moov_duration_mismatch => "MP4_MOOV_DURATION_MISMATCH",
        };
    }
};

/// Issue emitted during MP4-specific parsing and table inspection.
pub const Mp4Issue = struct {
    code: Mp4IssueCode,
    track_id: ?u32 = null,
    offset: u64 = 0,
    details: []const u8 = "",
};
