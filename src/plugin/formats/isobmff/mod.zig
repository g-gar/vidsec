const std = @import("std");

pub const types = @import("types.zig");
pub const reader = @import("reader.zig");
pub const checks = @import("checks/mod.zig");

// Re-export core types
pub const FourCC = types.FourCC;
pub const BoxHeader = types.BoxHeader;
pub const FullBoxHeader = types.FullBoxHeader;
pub const ParsedBox = types.ParsedBox;
pub const BoxRole = types.BoxRole;
pub const ParserIssue = types.ParserIssue;
pub const ParserIssueCode = types.ParserIssueCode;
pub const isContainerBox = types.isContainerBox;
pub const isPaddingBox = types.isPaddingBox;

// Re-export reader & parser
pub const ByteSource = reader.ByteSource;
pub const SafeBoxParser = reader.SafeBoxParser;
pub const ParseResult = reader.ParseResult;
pub const readBoxHeader = reader.readBoxHeader;
pub const toRegions = reader.toRegions;
pub const toElementSpans = reader.toElementSpans;


