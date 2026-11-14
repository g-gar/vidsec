const std = @import("std");

pub const types = @import("types.zig");
pub const parser = @import("parser.zig");

// Re-export MP4 types
pub const FourCC = types.FourCC;
pub const FtypInfo = types.FtypInfo;
pub const TrackInfo = types.TrackInfo;
pub const AvcCConfig = types.AvcCConfig;
pub const EsdsConfig = types.EsdsConfig;
pub const Mp4Issue = types.Mp4Issue;
pub const Mp4IssueCode = types.Mp4IssueCode;

// Re-export inspector
pub const Mp4Inspector = parser.Mp4Inspector;
pub const Mp4InspectionResult = parser.Mp4InspectionResult;


