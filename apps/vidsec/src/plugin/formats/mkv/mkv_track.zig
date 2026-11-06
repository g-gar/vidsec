const MkvTrackType = @import("mkv_track_type.zig").MkvTrackType;
const MkvVideoConfig = @import("mkv_video_config.zig").MkvVideoConfig;
const MkvAudioConfig = @import("mkv_audio_config.zig").MkvAudioConfig;
const MkvAvcConfig = @import("mkv_avc_config.zig").MkvAvcConfig;

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
