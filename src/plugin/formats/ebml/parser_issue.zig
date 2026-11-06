const std = @import("std");
const ParserIssueCode = @import("parser_issue_code.zig").ParserIssueCode;

/// Structural issue detected during EBML container parsing.
pub const ParserIssue = struct {
    code: ParserIssueCode,
    offset: u64,
    element_id: ?u32 = null,
    details: []const u8,
};
