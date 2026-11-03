const std = @import("std");
const common = @import("vidsec_formats_common");

pub const fourcc = @import("fourcc.zig");
pub const riff_constants = @import("riff_constants.zig");
pub const chunk_role = @import("chunk_role.zig");
pub const chunk_header = @import("chunk_header.zig");
pub const parsed_chunk = @import("parsed_chunk.zig");
pub const parser_issue_code = @import("parser_issue_code.zig");
pub const parser_issue = @import("parser_issue.zig");

// Re-exports
pub const ByteSource = common.ByteSource;
pub const FourCC = fourcc.FourCC;

pub const FOURCC_RIFF = riff_constants.FOURCC_RIFF;
pub const FOURCC_RIFX = riff_constants.FOURCC_RIFX;
pub const FOURCC_RF64 = riff_constants.FOURCC_RF64;
pub const FOURCC_LIST = riff_constants.FOURCC_LIST;

pub const FORM_AVI = riff_constants.FORM_AVI;
pub const FORM_AVIX = riff_constants.FORM_AVIX;
pub const FORM_WAVE = riff_constants.FORM_WAVE;
pub const FORM_WEBP = riff_constants.FORM_WEBP;
pub const FORM_ACON = riff_constants.FORM_ACON;

pub const LIST_HDRL = riff_constants.LIST_HDRL;
pub const LIST_MOVI = riff_constants.LIST_MOVI;
pub const LIST_STRL = riff_constants.LIST_STRL;
pub const LIST_ODML = riff_constants.LIST_ODML;
pub const LIST_INFO = riff_constants.LIST_INFO;

pub const CHUNK_AVIH = riff_constants.CHUNK_AVIH;
pub const CHUNK_STRH = riff_constants.CHUNK_STRH;
pub const CHUNK_STRF = riff_constants.CHUNK_STRF;
pub const CHUNK_STRD = riff_constants.CHUNK_STRD;
pub const CHUNK_STRN = riff_constants.CHUNK_STRN;
pub const CHUNK_IDX1 = riff_constants.CHUNK_IDX1;
pub const CHUNK_INDX = riff_constants.CHUNK_INDX;
pub const CHUNK_JUNK = riff_constants.CHUNK_JUNK;
pub const CHUNK_PAD = riff_constants.CHUNK_PAD;
pub const CHUNK_FMT = riff_constants.CHUNK_FMT;
pub const CHUNK_DATA = riff_constants.CHUNK_DATA;

pub const ChunkRole = chunk_role.ChunkRole;
pub const ChunkHeader = chunk_header.ChunkHeader;
pub const ParsedChunk = parsed_chunk.ParsedChunk;
pub const ParserIssueCode = parser_issue_code.ParserIssueCode;
pub const ParserIssue = parser_issue.ParserIssue;
