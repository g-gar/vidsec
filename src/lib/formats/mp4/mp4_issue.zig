const Mp4IssueCode = @import("mp4_issue_code.zig").Mp4IssueCode;

/// Issue emitted during MP4-specific parsing and table inspection.
pub const Mp4Issue = struct {
    code: Mp4IssueCode,
    track_id: ?u32 = null,
    offset: u64 = 0,
    details: []const u8 = "",
};
