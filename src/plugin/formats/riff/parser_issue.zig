const FourCC = @import("fourcc.zig").FourCC;
const ParserIssueCode = @import("parser_issue_code.zig").ParserIssueCode;

/// Structural issue detected during RIFF container parsing.
pub const ParserIssue = struct {
    code: ParserIssueCode,
    offset: u64,
    fourcc: ?FourCC = null,
    details: []const u8,
};
