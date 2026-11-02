const std = @import("std");
const ebml = @import("vidsec_ebml");

pub const ByteSource = ebml.ByteSource;
pub const ParsedElement = ebml.ParsedElement;
pub const ElementHeader = ebml.ElementHeader;

pub const MkvTrackType = enum(u8) {
    video = 1,
    audio = 2,
    complex = 3,
    logo = 0x10,
    subtitle = 0x11,
    buttons = 0x12,
    control = 0x20,
    unknown = 0xFF,

    pub fn fromInt(val: u64) MkvTrackType {
        return switch (val) {
            1 => .video,
            2 => .audio,
            3 => .complex,
            0x10 => .logo,
            0x11 => .subtitle,
            0x12 => .buttons,
            0x20 => .control,
            else => .unknown,
        };
    }

    pub fn asText(self: MkvTrackType) []const u8 {
        return switch (self) {
            .video => "video",
            .audio => "audio",
            .complex => "complex",
            .logo => "logo",
            .subtitle => "subtitle",
            .buttons => "buttons",
            .control => "control",
            .unknown => "unknown",
        };
    }
};

pub const MkvVideoConfig = struct {
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    display_width: u32 = 0,
    display_height: u32 = 0,
};

pub const MkvAudioConfig = struct {
    sampling_frequency: f64 = 8000.0,
    channels: u32 = 1,
    bit_depth: u32 = 0,
};

pub const MkvAvcConfig = struct {
    profile: u8,
    level: u8,
    sps_count: u8,
    pps_count: u8,
    sps_bytes_total: u32,
    pps_bytes_total: u32,
};

pub const MkvTrack = struct {
    track_number: u32,
    track_uid: u64,
    track_type: MkvTrackType,
    codec_id: []const u8,
    codec_name: []const u8,
    default_duration_ns: u64 = 0,
    video: ?MkvVideoConfig = null,
    audio: ?MkvAudioConfig = null,
    codec_private_size: u64 = 0,
    avcc: ?MkvAvcConfig = null,

    pub fn isVideo(self: MkvTrack) bool {
        return self.track_type == .video;
    }

    pub fn isAudio(self: MkvTrack) bool {
        return self.track_type == .audio;
    }
};

pub const MkvInfo = struct {
    timecode_scale: u64 = 1_000_000, // nanoseconds per tick (1ms default)
    duration_ticks: f64 = 0.0,
    muxing_app: []const u8 = "",
    writing_app: []const u8 = "",

    pub fn durationSeconds(self: MkvInfo) f64 {
        if (self.timecode_scale == 0) return 0.0;
        const total_ns = self.duration_ticks * @as(f64, @floatFromInt(self.timecode_scale));
        return total_ns / 1_000_000_000.0;
    }
};

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

pub const MkvIssue = struct {
    code: MkvIssueCode,
    track_number: ?u32 = null,
    offset: u64 = 0,
    details: []const u8,
};

pub const MkvInspectionResult = struct {
    info: MkvInfo,
    tracks: []const MkvTrack,
    issues: []const MkvIssue,
    cluster_count: u32,
    total_cluster_bytes: u64,
    unreferenced_cluster_slack: u64,
};
