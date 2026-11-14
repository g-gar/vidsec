const std = @import("std");
const isobmff = @import("../box/mod.zig");

pub const mp4_constants = @import("mp4_constants.zig");
pub const ftyp_info = @import("ftyp_info.zig");
pub const avcc_config = @import("avcc_config.zig");
pub const esds_config = @import("esds_config.zig");
pub const track_info = @import("track_info.zig");
pub const mp4_issue_code = @import("mp4_issue_code.zig");
pub const mp4_issue = @import("mp4_issue.zig");

// Re-exports from isobmff
pub const FourCC = isobmff.FourCC;
pub const ParsedBox = isobmff.ParsedBox;
pub const BoxHeader = isobmff.BoxHeader;
pub const FullBoxHeader = isobmff.FullBoxHeader;
pub const ByteSource = isobmff.ByteSource;

// Re-exports from mp4_constants
pub const BRAND_ISOM = mp4_constants.BRAND_ISOM;
pub const BRAND_ISO2 = mp4_constants.BRAND_ISO2;
pub const BRAND_MP41 = mp4_constants.BRAND_MP41;
pub const BRAND_MP42 = mp4_constants.BRAND_MP42;
pub const BRAND_AVC1 = mp4_constants.BRAND_AVC1;
pub const BRAND_DASH = mp4_constants.BRAND_DASH;
pub const BRAND_M4A = mp4_constants.BRAND_M4A;
pub const BRAND_M4V = mp4_constants.BRAND_M4V;
pub const BRAND_QT = mp4_constants.BRAND_QT;

pub const HANDLER_VIDE = mp4_constants.HANDLER_VIDE;
pub const HANDLER_SOUN = mp4_constants.HANDLER_SOUN;
pub const HANDLER_HINT = mp4_constants.HANDLER_HINT;
pub const HANDLER_META = mp4_constants.HANDLER_META;
pub const HANDLER_SUBT = mp4_constants.HANDLER_SUBT;
pub const HANDLER_TX3G = mp4_constants.HANDLER_TX3G;

pub const CODEC_AVC1 = mp4_constants.CODEC_AVC1;
pub const CODEC_AVC3 = mp4_constants.CODEC_AVC3;
pub const CODEC_HVC1 = mp4_constants.CODEC_HVC1;
pub const CODEC_HEV1 = mp4_constants.CODEC_HEV1;
pub const CODEC_MP4A = mp4_constants.CODEC_MP4A;
pub const CODEC_MP4V = mp4_constants.CODEC_MP4V;
pub const CODEC_AC3 = mp4_constants.CODEC_AC3;
pub const CODEC_EAC3 = mp4_constants.CODEC_EAC3;
pub const CODEC_OPUS = mp4_constants.CODEC_OPUS;
pub const CODEC_VP09 = mp4_constants.CODEC_VP09;
pub const CODEC_AV01 = mp4_constants.CODEC_AV01;
pub const CODEC_NONE = mp4_constants.CODEC_NONE;

pub const BOX_AVCC = mp4_constants.BOX_AVCC;
pub const BOX_HVCC = mp4_constants.BOX_HVCC;
pub const BOX_ESDS = mp4_constants.BOX_ESDS;
pub const BOX_PASP = mp4_constants.BOX_PASP;
pub const BOX_COLR = mp4_constants.BOX_COLR;

pub const FtypInfo = ftyp_info.FtypInfo;
pub const AvcCConfig = avcc_config.AvcCConfig;
pub const EsdsConfig = esds_config.EsdsConfig;
pub const TrackInfo = track_info.TrackInfo;
pub const Mp4IssueCode = mp4_issue_code.Mp4IssueCode;
pub const Mp4Issue = mp4_issue.Mp4Issue;
