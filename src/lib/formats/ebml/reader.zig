const std = @import("std");
const common = @import("vidsec_formats_common");

pub const safe_ebml_parser = @import("safe_ebml_parser.zig");
pub const ebml_parser_options = @import("ebml_parser_options.zig");
pub const ebml_parse_result = @import("ebml_parse_result.zig");
pub const read_element_header = @import("read_element_header.zig");
pub const to_element_spans = @import("to_element_spans.zig");

// Re-exports
pub const ByteSource = common.ByteSource;
pub const SafeEbmlParser = safe_ebml_parser.SafeEbmlParser;
pub const MAX_NESTING_DEPTH = safe_ebml_parser.MAX_NESTING_DEPTH;
pub const EbmlParserOptions = ebml_parser_options.EbmlParserOptions;
pub const EbmlParseResult = ebml_parse_result.EbmlParseResult;
pub const readElementHeader = read_element_header.readElementHeader;
pub const toRegions = to_element_spans.toRegions;
pub const toElementSpans = to_element_spans.toElementSpans;
