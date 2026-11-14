const std = @import("std");
const Allocator = std.mem.Allocator;
const ParsedBox = @import("parsed_box.zig").ParsedBox;
const ParserIssue = @import("parser_issue.zig").ParserIssue;

/// Result of parsing an ISOBMFF container stream.
pub const ParseResult = struct {
    boxes: []const ParsedBox,
    issues: []const ParserIssue,
    highest_root_end: u64 = 0,
    has_ftyp: bool = false,
    has_moov: bool = false,
    moov_count: u32 = 0,
    ftyp_count: u32 = 0,

    pub fn deinit(self: ParseResult, allocator: Allocator) void {
        allocator.free(self.boxes);
        allocator.free(self.issues);
    }
};
