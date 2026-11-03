const std = @import("std");
const FtypInfo = @import("ftyp_info.zig").FtypInfo;
const TrackInfo = @import("track_info.zig").TrackInfo;
const Mp4Issue = @import("mp4_issue.zig").Mp4Issue;

/// Complete structural and semantic inspection result for an MP4 container.
pub const Mp4InspectionResult = struct {
    ftyp: ?FtypInfo = null,
    tracks: []const TrackInfo,
    issues: []const Mp4Issue,
    total_samples: u64 = 0,
    total_sample_bytes: u64 = 0,
    total_mdat_bytes: u64 = 0,
    unreferenced_mdat_slack: u64 = 0,

    pub fn deinit(self: Mp4InspectionResult, allocator: std.mem.Allocator) void {
        if (self.ftyp) |f| {
            allocator.free(f.compatible_brands);
        }
        allocator.free(self.tracks);
        allocator.free(self.issues);
    }
};
