const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const ebml = @import("ebml");
const media_ir = @import("media_ir");
const common = @import("common.zig");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
};

pub const CheckRow = struct {
    track_count: u64,
    tracks_valid: bool,
};

pub const OutputsData = struct {
    mkv_tracks_check: CheckRow,
    audit_findings: []const media_ir.AuditFindingRow,
};

pub const Outputs = abi.Channels(OutputsData);

/// Atomic Matroska check: validates `Tracks` presence, track numbers, CodecID, and `avcC` `CodecPrivate` before IR lowering.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        const parsed = try ebml.ebml.SafeEbmlParser.init(alloc, .{}).parse(source);
        defer parsed.deinit(alloc);

        const inspector = ebml.mkv.MkvInspector.init(alloc);
        var tracks = std.ArrayList(ebml.mkv.MkvTrack).empty;
        defer tracks.deinit(alloc);

        var issues = std.ArrayList(ebml.mkv.MkvIssue).empty;
        defer issues.deinit(alloc);

        var seen_track_numbers = std.AutoHashMap(u32, void).init(alloc);
        defer seen_track_numbers.deinit();

        var has_tracks = false;
        for (parsed.elements, 0..) |elem, idx| {
            if (elem.id == ebml.ebml.types.ID_TRACKS) {
                has_tracks = true;
                try inspector.parseTracks(source, parsed.elements, idx, &tracks, &issues, &seen_track_numbers);
            }
        }

        if (!has_tracks) {
            try issues.append(alloc, .{
                .code = .segment_missing_tracks,
                .offset = 0,
                .details = "Segment is missing required Tracks element (0x1654AE6B)",
            });
        }

        const findings = try common.collectFindings(alloc, &.{}, &.{}, &.{}, issues.items);

        return .{ .data = .{
            .mkv_tracks_check = .{
                .track_count = tracks.items.len,
                .tracks_valid = issues.items.len == 0,
            },
            .audit_findings = findings,
        } };
    }
};

