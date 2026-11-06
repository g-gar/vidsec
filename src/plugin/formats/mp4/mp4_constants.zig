const isobmff = @import("vidsec_isobmff");
const FourCC = isobmff.FourCC;

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
