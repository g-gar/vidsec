const std = @import("std");
const Allocator = std.mem.Allocator;
const ebml = @import("../ebml/mod.zig");
const types = @import("types.zig");

pub const ByteSource = ebml.ByteSource;
pub const ParsedElement = ebml.ParsedElement;
pub const ElementHeader = ebml.ElementHeader;
pub const vint = ebml.vint;

pub const MkvTrack = types.MkvTrack;
pub const MkvTrackType = types.MkvTrackType;
pub const MkvVideoConfig = types.MkvVideoConfig;
pub const MkvAudioConfig = types.MkvAudioConfig;
pub const MkvAvcConfig = types.MkvAvcConfig;
pub const MkvInfo = types.MkvInfo;
pub const MkvIssue = types.MkvIssue;
pub const MkvIssueCode = types.MkvIssueCode;
pub const MkvInspectionResult = types.MkvInspectionResult;

pub const MkvInspector = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) MkvInspector {
        return .{ .allocator = allocator };
    }

    pub fn inspect(
        self: MkvInspector,
        source: ByteSource,
        elements: []const ParsedElement,
    ) !MkvInspectionResult {
        var issues = std.ArrayList(MkvIssue).empty;
        errdefer issues.deinit(self.allocator);

        var tracks = std.ArrayList(MkvTrack).empty;
        errdefer tracks.deinit(self.allocator);

        var seen_track_numbers = std.AutoHashMap(u32, void).init(self.allocator);
        defer seen_track_numbers.deinit();

        var info = MkvInfo{};
        var has_tracks_element = false;
        var cluster_count: u32 = 0;
        var total_cluster_bytes: u64 = 0;

        for (elements, 0..) |elem, idx| {
            if (elem.id == ebml.types.ID_INFO) {
                info = try self.parseInfo(source, elements, idx);
            } else if (elem.id == ebml.types.ID_TRACKS) {
                has_tracks_element = true;
                try self.parseTracks(source, elements, idx, &tracks, &issues, &seen_track_numbers);
            } else if (elem.id == ebml.types.ID_CLUSTER) {
                cluster_count += 1;
                total_cluster_bytes += elem.header.totalSize();
            }
        }

        if (!has_tracks_element) {
            try issues.append(self.allocator, .{
                .code = .segment_missing_tracks,
                .offset = 0,
                .details = "Segment is missing required Tracks element (0x1654AE6B)",
            });
        }

        return MkvInspectionResult{
            .info = info,
            .tracks = try tracks.toOwnedSlice(self.allocator),
            .issues = try issues.toOwnedSlice(self.allocator),
            .cluster_count = cluster_count,
            .total_cluster_bytes = total_cluster_bytes,
            .unreferenced_cluster_slack = 0,
        };
    }

    fn parseInfo(
        self: MkvInspector,
        source: ByteSource,
        elements: []const ParsedElement,
        info_idx: usize,
    ) !MkvInfo {
        var info = MkvInfo{};
        var str_buf: [256]u8 = undefined;

        for (elements, 0..) |elem, idx| {
            if (idx <= info_idx) continue;
            if (elem.parent_id != @as(u32, @intCast(info_idx))) continue;

            if (elem.id == ebml.types.ID_TIMECODE_SCALE) {
                info.timecode_scale = try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size);
            } else if (elem.id == ebml.types.ID_DURATION) {
                info.duration_ticks = try vint.readFloat(source, elem.header.payloadOffset(), elem.header.data_size);
            } else if (elem.id == ebml.types.ID_MUXING_APP) {
                const s = try vint.readString(source, &str_buf, elem.header.payloadOffset(), elem.header.data_size);
                if (s.len > 0) info.muxing_app = try self.allocator.dupe(u8, s);
            } else if (elem.id == ebml.types.ID_WRITING_APP) {
                const s = try vint.readString(source, &str_buf, elem.header.payloadOffset(), elem.header.data_size);
                if (s.len > 0) info.writing_app = try self.allocator.dupe(u8, s);
            }
        }

        return info;
    }

    fn parseTracks(
        self: MkvInspector,
        source: ByteSource,
        elements: []const ParsedElement,
        tracks_idx: usize,
        out_tracks: *std.ArrayList(MkvTrack),
        issues: *std.ArrayList(MkvIssue),
        seen_track_numbers: *std.AutoHashMap(u32, void),
    ) !void {
        for (elements, 0..) |elem, idx| {
            if (idx <= tracks_idx) continue;
            if (elem.parent_id != @as(u32, @intCast(tracks_idx))) continue;

            if (elem.id == ebml.types.ID_TRACK_ENTRY) {
                const track_opt = try self.parseTrackEntry(source, elements, idx, issues, seen_track_numbers);
                if (track_opt) |t| {
                    try out_tracks.append(self.allocator, t);
                }
            }
        }
    }

    fn parseTrackEntry(
        self: MkvInspector,
        source: ByteSource,
        elements: []const ParsedElement,
        entry_idx: usize,
        issues: *std.ArrayList(MkvIssue),
        seen_track_numbers: *std.AutoHashMap(u32, void),
    ) !?MkvTrack {
        var track_number: u32 = 0;
        var track_uid: u64 = 0;
        var track_type: MkvTrackType = .unknown;
        var codec_id_str: []const u8 = "";
        var codec_name_str: []const u8 = "";
        var default_duration: u64 = 0;
        var codec_private_size: u64 = 0;
        var avcc_config: ?MkvAvcConfig = null;

        var video_cfg: ?MkvVideoConfig = null;
        var audio_cfg: ?MkvAudioConfig = null;

        var str_buf: [128]u8 = undefined;

        for (elements, 0..) |elem, idx| {
            if (idx <= entry_idx) continue;
            if (elem.parent_id != @as(u32, @intCast(entry_idx))) continue;

            if (elem.id == ebml.types.ID_TRACK_NUMBER) {
                track_number = @truncate(try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size));
                if (track_number == 0) {
                    try issues.append(self.allocator, .{
                        .code = .track_number_zero,
                        .track_number = 0,
                        .offset = elem.header.offset,
                        .details = "TrackEntry specifies illegal TrackNumber = 0",
                    });
                } else if (seen_track_numbers.contains(track_number)) {
                    try issues.append(self.allocator, .{
                        .code = .track_number_duplicate,
                        .track_number = track_number,
                        .offset = elem.header.offset,
                        .details = "Duplicate TrackNumber encountered in multiple TrackEntry elements",
                    });
                } else {
                    try seen_track_numbers.put(track_number, {});
                }
            } else if (elem.id == ebml.types.ID_TRACK_UID) {
                track_uid = try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size);
            } else if (elem.id == ebml.types.ID_TRACK_TYPE) {
                const val = try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size);
                track_type = MkvTrackType.fromInt(val);
            } else if (elem.id == ebml.types.ID_CODEC_ID) {
                const s = try vint.readString(source, &str_buf, elem.header.payloadOffset(), elem.header.data_size);
                codec_id_str = try self.allocator.dupe(u8, s);
            } else if (elem.id == ebml.types.ID_CODEC_NAME) {
                const s = try vint.readString(source, &str_buf, elem.header.payloadOffset(), elem.header.data_size);
                codec_name_str = try self.allocator.dupe(u8, s);
            } else if (elem.id == ebml.types.ID_DEFAULT_DURATION) {
                default_duration = try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size);
            } else if (elem.id == ebml.types.ID_CODEC_PRIVATE) {
                codec_private_size = elem.header.data_size;
                // Parse avcC if this is an H.264 track
                if (std.mem.eql(u8, codec_id_str, "V_MPEG4/ISO/AVC") and elem.header.data_size >= 7) {
                    avcc_config = try self.parseAvcC(source, elem.header, track_number, issues);
                }
            } else if (elem.id == ebml.types.ID_VIDEO) {
                video_cfg = try self.parseVideoElement(source, elements, idx);
            } else if (elem.id == ebml.types.ID_AUDIO) {
                audio_cfg = try self.parseAudioElement(source, elements, idx);
            }
        }

        // If CodecPrivate was encountered before CodecID, retry parsing avcC
        if (avcc_config == null and std.mem.eql(u8, codec_id_str, "V_MPEG4/ISO/AVC")) {
            for (elements, 0..) |elem, idx| {
                if (idx <= entry_idx) continue;
                if (elem.parent_id != @as(u32, @intCast(entry_idx))) continue;
                if (elem.id == ebml.types.ID_CODEC_PRIVATE and elem.header.data_size >= 7) {
                    avcc_config = try self.parseAvcC(source, elem.header, track_number, issues);
                    break;
                }
            }
        }

        if (codec_id_str.len == 0) {
            try issues.append(self.allocator, .{
                .code = .track_missing_codec_id,
                .track_number = track_number,
                .offset = elements[entry_idx].header.offset,
                .details = "TrackEntry is missing required CodecID element",
            });
        }

        return MkvTrack{
            .track_number = track_number,
            .track_uid = track_uid,
            .track_type = track_type,
            .codec_id = codec_id_str,
            .codec_name = codec_name_str,
            .default_duration_ns = default_duration,
            .video = video_cfg,
            .audio = audio_cfg,
            .codec_private_size = codec_private_size,
            .avcc = avcc_config,
        };
    }

    fn parseVideoElement(
        self: MkvInspector,
        source: ByteSource,
        elements: []const ParsedElement,
        video_idx: usize,
    ) !MkvVideoConfig {
        _ = self;
        var cfg = MkvVideoConfig{};

        for (elements, 0..) |elem, idx| {
            if (idx <= video_idx) continue;
            if (elem.parent_id != @as(u32, @intCast(video_idx))) continue;

            if (elem.id == ebml.types.ID_PIXEL_WIDTH) {
                cfg.pixel_width = @truncate(try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size));
            } else if (elem.id == ebml.types.ID_PIXEL_HEIGHT) {
                cfg.pixel_height = @truncate(try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size));
            } else if (elem.id == ebml.types.ID_DISPLAY_WIDTH) {
                cfg.display_width = @truncate(try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size));
            } else if (elem.id == ebml.types.ID_DISPLAY_HEIGHT) {
                cfg.display_height = @truncate(try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size));
            }
        }

        return cfg;
    }

    fn parseAudioElement(
        self: MkvInspector,
        source: ByteSource,
        elements: []const ParsedElement,
        audio_idx: usize,
    ) !MkvAudioConfig {
        _ = self;
        var cfg = MkvAudioConfig{};

        for (elements, 0..) |elem, idx| {
            if (idx <= audio_idx) continue;
            if (elem.parent_id != @as(u32, @intCast(audio_idx))) continue;

            if (elem.id == ebml.types.ID_SAMPLING_FREQUENCY) {
                cfg.sampling_frequency = try vint.readFloat(source, elem.header.payloadOffset(), elem.header.data_size);
            } else if (elem.id == ebml.types.ID_CHANNELS) {
                cfg.channels = @truncate(try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size));
            } else if (elem.id == ebml.types.ID_BIT_DEPTH) {
                cfg.bit_depth = @truncate(try vint.readUint(source, elem.header.payloadOffset(), elem.header.data_size));
            }
        }

        return cfg;
    }

    fn parseAvcC(
        self: MkvInspector,
        source: ByteSource,
        header: ElementHeader,
        track_number: u32,
        issues: *std.ArrayList(MkvIssue),
    ) !?MkvAvcConfig {
        if (header.data_size < 7) return null;

        var buf: [64]u8 = undefined;
        const read_n = try source.readAt(&buf, header.payloadOffset());
        if (read_n < 7) return null;

        const profile = buf[1];
        const level = buf[3];
        const num_sps = buf[5] & 0x1F;

        var cursor: usize = 6;
        var sps_bytes_total: u32 = 0;

        var i: u8 = 0;
        while (i < num_sps and cursor + 2 <= read_n) : (i += 1) {
            const sps_len = std.mem.readInt(u16, buf[cursor..][0..2], .big);
            cursor += 2;
            sps_bytes_total += sps_len;

            if (cursor + sps_len > header.data_size) {
                try issues.append(self.allocator, .{
                    .code = .avcc_sps_length_overflow,
                    .track_number = track_number,
                    .offset = header.payloadOffset() + cursor - 2,
                    .details = "CodecPrivate SPS length extends beyond element boundary",
                });
                break;
            }
            cursor += sps_len;
        }

        var num_pps: u8 = 0;
        var pps_bytes_total: u32 = 0;

        if (cursor < read_n) {
            num_pps = buf[cursor];
            cursor += 1;

            var j: u8 = 0;
            while (j < num_pps and cursor + 2 <= read_n) : (j += 1) {
                const pps_len = std.mem.readInt(u16, buf[cursor..][0..2], .big);
                cursor += 2;
                pps_bytes_total += pps_len;

                if (cursor + pps_len > header.data_size) {
                    try issues.append(self.allocator, .{
                        .code = .avcc_pps_length_overflow,
                        .track_number = track_number,
                        .offset = header.payloadOffset() + cursor - 2,
                        .details = "CodecPrivate PPS length extends beyond element boundary",
                    });
                    break;
                }
                cursor += pps_len;
            }
        }

        return MkvAvcConfig{
            .profile = profile,
            .level = level,
            .sps_count = num_sps,
            .pps_count = num_pps,
            .sps_bytes_total = sps_bytes_total,
            .pps_bytes_total = pps_bytes_total,
        };
    }
};
