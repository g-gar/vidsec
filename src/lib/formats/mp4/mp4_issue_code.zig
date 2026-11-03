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
