pub const MkvIssueCode = enum {
    track_number_zero,
    track_number_duplicate,
    track_missing_codec_id,
    segment_missing_tracks,
    avcc_sps_length_overflow,
    avcc_pps_length_overflow,
    unreferenced_cluster_slack,
    cluster_timecode_out_of_order,

    pub fn asText(self: MkvIssueCode) []const u8 {
        return switch (self) {
            .track_number_zero => "MKV_TRACK_NUMBER_ZERO",
            .track_number_duplicate => "MKV_TRACK_NUMBER_DUPLICATE",
            .track_missing_codec_id => "MKV_TRACK_MISSING_CODEC_ID",
            .segment_missing_tracks => "MKV_SEGMENT_MISSING_TRACKS",
            .avcc_sps_length_overflow => "MKV_AVCC_SPS_LENGTH_OVERFLOW",
            .avcc_pps_length_overflow => "MKV_AVCC_PPS_LENGTH_OVERFLOW",
            .unreferenced_cluster_slack => "MKV_UNREFERENCED_CLUSTER_SLACK",
            .cluster_timecode_out_of_order => "MKV_CLUSTER_TIMECODE_OUT_OF_ORDER",
        };
    }
};
