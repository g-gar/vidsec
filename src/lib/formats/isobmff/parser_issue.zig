const std = @import("std");
const FourCC = @import("fourcc.zig").FourCC;
const ParserIssueCode = @import("parser_issue_code.zig").ParserIssueCode;

/// Structural fact/issue emitted by the pure ISOBMFF parser (without triage/security policy).
pub const ParserIssue = struct {
    code: ParserIssueCode,
    offset: u64,
    fourcc: ?FourCC = null,
    details: []const u8 = "",
};
