const MkvIssueCode = @import("mkv_issue_code.zig").MkvIssueCode;

pub const MkvIssue = struct {
    code: MkvIssueCode,
    track_number: ?u32 = null,
    offset: u64 = 0,
    details: []const u8,
};
