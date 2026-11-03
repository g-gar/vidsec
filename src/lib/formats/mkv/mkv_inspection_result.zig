const MkvInfo = @import("mkv_info.zig").MkvInfo;
const MkvTrack = @import("mkv_track.zig").MkvTrack;
const MkvIssue = @import("mkv_issue.zig").MkvIssue;

pub const MkvInspectionResult = struct {
    info: MkvInfo,
    tracks: []const MkvTrack,
    issues: []const MkvIssue,
    cluster_count: u32,
    total_cluster_bytes: u64,
    unreferenced_cluster_slack: u64,
};
