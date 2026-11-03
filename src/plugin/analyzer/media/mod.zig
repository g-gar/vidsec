pub const strategy = @import("strategy.zig");
pub const MediaLoweringStrategy = strategy.MediaLoweringStrategy;
pub const SampleLoweringStrategy = strategy.SampleLoweringStrategy;
pub const LowerTracksFn = strategy.LowerTracksFn;

pub const mp4_strategy = @import("mp4_strategy.zig");
pub const Mp4MediaStrategy = mp4_strategy.Mp4MediaStrategy;
pub const lowerMp4Tracks = mp4_strategy.lowerMp4Tracks;

pub const mkv_strategy = @import("mkv_strategy.zig");
pub const MkvMediaStrategy = mkv_strategy.MkvMediaStrategy;
pub const lowerMkvTracks = mkv_strategy.lowerMkvTracks;

pub const samples_strategy = @import("samples_strategy.zig");
pub const DefaultSampleStrategy = samples_strategy.DefaultSampleStrategy;
pub const lowerSampleExtents = samples_strategy.lowerSampleExtents;

pub const factory = @import("factory.zig");
pub const getMediaLoweringStrategy = factory.getMediaLoweringStrategy;

pub const mp4_media = @import("mp4_media.zig");
pub const LowerMp4MediaInputs = mp4_media.LowerMp4MediaInputs;
pub const runLowerMp4Media = mp4_media.runLowerMp4Media;

pub const mkv_media = @import("mkv_media.zig");
pub const LowerMkvMediaInputs = mkv_media.LowerMkvMediaInputs;
pub const runLowerMkvMedia = mkv_media.runLowerMkvMedia;
