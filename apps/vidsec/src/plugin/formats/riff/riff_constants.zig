const FourCC = @import("fourcc.zig").FourCC;

// Root Container Types
pub const FOURCC_RIFF = FourCC.init("RIFF"); // Little-endian standard RIFF
pub const FOURCC_RIFX = FourCC.init("RIFX"); // Big-endian RIFF
pub const FOURCC_RF64 = FourCC.init("RF64"); // 64-bit extensible RIFF
pub const FOURCC_LIST = FourCC.init("LIST"); // Container chunk

// Common Form Types
pub const FORM_AVI  = FourCC.init("AVI ");
pub const FORM_AVIX = FourCC.init("AVIX");
pub const FORM_WAVE = FourCC.init("WAVE");
pub const FORM_WEBP = FourCC.init("WEBP");
pub const FORM_ACON = FourCC.init("ACON");

// Common List Types
pub const LIST_HDRL = FourCC.init("hdrl"); // AVI header list
pub const LIST_MOVI = FourCC.init("movi"); // AVI movie data list
pub const LIST_STRL = FourCC.init("strl"); // AVI stream list
pub const LIST_ODML = FourCC.init("odml"); // OpenDML extended AVI
pub const LIST_INFO = FourCC.init("INFO"); // Metadata list

// Common Chunk Types
pub const CHUNK_AVIH = FourCC.init("avih"); // Main AVI header
pub const CHUNK_STRH = FourCC.init("strh"); // Stream header
pub const CHUNK_STRF = FourCC.init("strf"); // Stream format
pub const CHUNK_STRD = FourCC.init("strd"); // Stream data
pub const CHUNK_STRN = FourCC.init("strn"); // Stream name
pub const CHUNK_IDX1 = FourCC.init("idx1"); // Legacy AVI index
pub const CHUNK_INDX = FourCC.init("indx"); // OpenDML super index
pub const CHUNK_JUNK = FourCC.init("JUNK"); // Padding / dead space
pub const CHUNK_PAD  = FourCC.init("PAD "); // Padding
pub const CHUNK_FMT  = FourCC.init("fmt "); // WAVE format chunk
pub const CHUNK_DATA = FourCC.init("data"); // WAVE audio data
