const std = @import("std");
const common = @import("media_ir").common;

pub const safe_box_parser = @import("safe_box_parser.zig");
pub const read_box_header = @import("read_box_header.zig");
pub const to_element_spans = @import("to_element_spans.zig");
pub const parse_result = @import("parse_result.zig");

// Re-exports
pub const ByteSource = common.ByteSource;
pub const SafeBoxParser = safe_box_parser.SafeBoxParser;
pub const MAX_NESTING_DEPTH = safe_box_parser.MAX_NESTING_DEPTH;
pub const ParseResult = parse_result.ParseResult;
pub const readBoxHeader = read_box_header.readBoxHeader;
pub const toRegions = to_element_spans.toRegions;
pub const toElementSpans = to_element_spans.toElementSpans;
