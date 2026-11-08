const std = @import("std");
const Allocator = std.mem.Allocator;
const FourCC = @import("fourcc.zig").FourCC;
const ParsedChunk = @import("parsed_chunk.zig").ParsedChunk;
const ParserIssue = @import("parser_issue.zig").ParserIssue;

/// Result of parsing a RIFF container stream.
pub const RiffParseResult = struct {
    chunks: []const ParsedChunk,
    issues: []const ParserIssue,
    form_type: FourCC,
    root_size: u64,
    movi_bytes: u64,
    junk_bytes: u64,
    highest_root_end: u64,
    trailing_slack_bytes: u64,

    pub fn deinit(self: RiffParseResult, allocator: Allocator) void {
        allocator.free(self.chunks);
        allocator.free(self.issues);
    }
};
