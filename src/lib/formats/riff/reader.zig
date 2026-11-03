const std = @import("std");
const common = @import("vidsec_formats_common");

pub const safe_riff_parser = @import("safe_riff_parser.zig");
pub const riff_parser_options = @import("riff_parser_options.zig");
pub const riff_parse_result = @import("riff_parse_result.zig");
pub const to_element_spans = @import("to_element_spans.zig");

// Re-exports
pub const ByteSource = common.ByteSource;
pub const SafeRiffParser = safe_riff_parser.SafeRiffParser;
pub const MAX_NESTING_DEPTH = safe_riff_parser.MAX_NESTING_DEPTH;
pub const RiffParserOptions = riff_parser_options.RiffParserOptions;
pub const RiffParseResult = riff_parse_result.RiffParseResult;
pub const toRegions = to_element_spans.toRegions;
pub const toElementSpans = to_element_spans.toElementSpans;
