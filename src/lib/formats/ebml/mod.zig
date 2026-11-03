pub const types = @import("types.zig");
pub const vint = @import("vint.zig");
pub const reader = @import("reader.zig");
pub const checks = @import("checks/mod.zig");

// Re-export common symbols for consumers
pub const ByteSource = types.ByteSource;
pub const Vint = types.Vint;
pub const ElementHeader = types.ElementHeader;
pub const ParsedElement = types.ParsedElement;
pub const ElementRole = types.ElementRole;
pub const ParserIssue = types.ParserIssue;
pub const ParserIssueCode = types.ParserIssueCode;
pub const isMasterElement = types.isMasterElement;

pub const readVint = vint.readVint;
pub const readVintSlice = vint.readVintSlice;
pub const readElementId = vint.readElementId;
pub const readDataSize = vint.readDataSize;
pub const readUint = vint.readUint;
pub const readFloat = vint.readFloat;
pub const readString = vint.readString;

pub const SafeEbmlParser = reader.SafeEbmlParser;
pub const EbmlParserOptions = reader.EbmlParserOptions;
pub const EbmlParseResult = reader.EbmlParseResult;
pub const readElementHeader = reader.readElementHeader;
pub const toRegions = reader.toRegions;
pub const toElementSpans = reader.toElementSpans;


