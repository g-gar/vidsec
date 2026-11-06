pub const strategy = @import("strategy.zig");
pub const MediaLoweringStrategy = strategy.MediaLoweringStrategy;
pub const SampleLoweringStrategy = strategy.SampleLoweringStrategy;
pub const LowerTracksFn = strategy.LowerTracksFn;
pub const LowerSamplesFn = strategy.LowerSamplesFn;
pub const TrackInput = strategy.TrackInput;
pub const SampleInput = strategy.SampleInput;

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
