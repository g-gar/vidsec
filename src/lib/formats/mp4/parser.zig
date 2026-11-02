const std = @import("std");
const isobmff = @import("vidsec_isobmff");
const types = @import("types.zig");

pub const FourCC = types.FourCC;
pub const ParsedBox = types.ParsedBox;
pub const ByteSource = types.ByteSource;
pub const FtypInfo = types.FtypInfo;
pub const TrackInfo = types.TrackInfo;
pub const AvcCConfig = types.AvcCConfig;
pub const EsdsConfig = types.EsdsConfig;
pub const Mp4Issue = types.Mp4Issue;
pub const Mp4IssueCode = types.Mp4IssueCode;

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

/// Pure, policy-free MP4 inspector.
pub const Mp4Inspector = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Mp4Inspector {
        return .{ .allocator = allocator };
    }

    pub fn inspect(
        self: Mp4Inspector,
        source: ByteSource,
        boxes: []const ParsedBox,
    ) !Mp4InspectionResult {
        var issues: std.ArrayList(Mp4Issue) = try .initCapacity(self.allocator, 8);
        errdefer issues.deinit(self.allocator);

        var tracks: std.ArrayList(TrackInfo) = try .initCapacity(self.allocator, 4);
        errdefer tracks.deinit(self.allocator);

        var ftyp_info: ?FtypInfo = null;
        var total_mdat_bytes: u64 = 0;
        var seen_track_ids: std.AutoHashMap(u32, void) = std.AutoHashMap(u32, void).init(self.allocator);
        defer seen_track_ids.deinit();

        // 1. First pass: locate ftyp, compute mdat byte totals
        for (boxes) |box| {
            if (box.header.fourcc.equals(isobmff.types.BOX_MDAT)) {
                total_mdat_bytes += box.header.size;
            } else if (box.header.fourcc.equals(isobmff.types.BOX_FTYP) and ftyp_info == null) {
                ftyp_info = try self.parseFtyp(source, box, &issues);
            }
        }

        // 2. Second pass: inspect each `trak` box
        for (boxes, 0..) |box, idx| {
            if (box.header.fourcc.equals(isobmff.types.BOX_TRAK)) {
                if (try self.inspectTrack(source, boxes, @intCast(idx), total_mdat_bytes, &issues, &seen_track_ids)) |tr| {
                    try tracks.append(self.allocator, tr);
                }
            }
        }

        // 3. Compute aggregate sample bytes and slack space in mdat
        var total_samples: u64 = 0;
        var total_sample_bytes: u64 = 0;

        for (tracks.items) |tr| {
            total_samples += tr.sample_count;
            total_sample_bytes += tr.total_sample_bytes;
        }

        const unreferenced_slack = if (total_mdat_bytes > total_sample_bytes)
            total_mdat_bytes - total_sample_bytes
        else
            0;

        if (total_mdat_bytes > 0 and unreferenced_slack > (64 * 1024)) {
            try issues.append(self.allocator, .{
                .code = .unreferenced_mdat_slack,
                .offset = 0,
                .details = "Unreferenced slack space inside mdat exceeds 64 KB",
            });
        }

        return .{
            .ftyp = ftyp_info,
            .tracks = try tracks.toOwnedSlice(self.allocator),
            .issues = try issues.toOwnedSlice(self.allocator),
            .total_samples = total_samples,
            .total_sample_bytes = total_sample_bytes,
            .total_mdat_bytes = total_mdat_bytes,
            .unreferenced_mdat_slack = unreferenced_slack,
        };
    }

    fn parseFtyp(
        self: Mp4Inspector,
        source: ByteSource,
        box: ParsedBox,
        issues: *std.ArrayList(Mp4Issue),
    ) !FtypInfo {
        const payload_size = box.header.payloadSize();
        if (payload_size < 8) {
            try issues.append(self.allocator, .{
                .code = .ftyp_truncated,
                .offset = box.header.offset,
                .details = "ftyp payload smaller than 8 bytes",
            });
            return .{
                .major_brand = types.BRAND_ISOM,
                .minor_version = 0,
                .compatible_brands = &[_]FourCC{},
            };
        }

        var hdr_buf: [8]u8 = undefined;
        _ = try source.readAt(&hdr_buf, box.header.payloadOffset());
        const major_brand = FourCC{ .bytes = hdr_buf[0..4].* };
        const minor_version = std.mem.readInt(u32, hdr_buf[4..8], .big);

        const comp_bytes = payload_size - 8;
        const comp_count = comp_bytes / 4;
        var comp_brands = try self.allocator.alloc(FourCC, comp_count);
        errdefer self.allocator.free(comp_brands);

        var i: usize = 0;
        while (i < comp_count) : (i += 1) {
            var b_buf: [4]u8 = undefined;
            const off = box.header.payloadOffset() + 8 + (i * 4);
            _ = try source.readAt(&b_buf, off);
            comp_brands[i] = FourCC{ .bytes = b_buf };
        }

        const info = FtypInfo{
            .major_brand = major_brand,
            .minor_version = minor_version,
            .compatible_brands = comp_brands,
        };

        const recognized = info.hasBrand(types.BRAND_ISOM) or
            info.hasBrand(types.BRAND_ISO2) or
            info.hasBrand(types.BRAND_MP41) or
            info.hasBrand(types.BRAND_MP42) or
            info.hasBrand(types.BRAND_AVC1) or
            info.hasBrand(types.BRAND_DASH) or
            info.hasBrand(types.BRAND_M4A) or
            info.hasBrand(types.BRAND_M4V) or
            info.hasBrand(types.BRAND_QT);

        if (!recognized) {
            try issues.append(self.allocator, .{
                .code = .ftyp_unrecognized_brand,
                .offset = box.header.offset,
                .details = "No standard ISOBMFF/MP4 brand recognized in ftyp",
            });
        }

        return info;
    }

    fn inspectTrack(
        self: Mp4Inspector,
        source: ByteSource,
        boxes: []const ParsedBox,
        track_box_idx: u32,
        _: u64,
        issues: *std.ArrayList(Mp4Issue),
        seen_track_ids: *std.AutoHashMap(u32, void),
    ) !?TrackInfo {
        var track_id: ?u32 = null;
        var duration: u64 = 0;
        var timescale: u32 = 0;
        var handler_type = types.HANDLER_VIDE;
        var codec_fourcc = types.CODEC_NONE;
        var width: u32 = 0;
        var height: u32 = 0;
        var sample_count: u32 = 0;
        var chunk_count: u32 = 0;
        var total_sample_bytes: u64 = 0;
        var avcc_config: ?AvcCConfig = null;
        var esds_config: ?EsdsConfig = null;

        var has_tkhd = false;
        var has_mdhd = false;

        // Iterate boxes belonging to this track hierarchy
        for (boxes) |b| {
            if (!isDescendantOf(boxes, b, track_box_idx)) continue;

            if (b.header.fourcc.equals(isobmff.types.BOX_TKHD)) {
                has_tkhd = true;
                const p_size = b.header.payloadSize();
                if (p_size >= 24) {
                    var buf: [32]u8 = undefined;
                    const read_n = try source.readAt(&buf, b.header.payloadOffset());
                    if (read_n >= 24) {
                        const version = buf[0];
                        const tid_offset: usize = if (version == 1) 20 else 12;
                        if (tid_offset + 4 <= read_n) {
                            const tid = std.mem.readInt(u32, buf[tid_offset..][0..4], .big);
                            track_id = tid;

                            if (tid == 0) {
                                try issues.append(self.allocator, .{
                                    .code = .track_id_zero,
                                    .track_id = 0,
                                    .offset = b.header.offset,
                                    .details = "tkhd declares illegal track_id = 0",
                                });
                            } else if (seen_track_ids.contains(tid)) {
                                try issues.append(self.allocator, .{
                                    .code = .track_id_duplicate,
                                    .track_id = tid,
                                    .offset = b.header.offset,
                                    .details = "Duplicate track_id encountered in multiple trak boxes",
                                });
                            } else {
                                try seen_track_ids.put(tid, {});
                            }
                        }
                    }
                }

                // Parse width and height from the end of tkhd (fixed-point 16.16)
                if (p_size >= 84) {
                    var dim_buf: [8]u8 = undefined;
                    const dim_off = b.header.payloadOffset() + p_size - 8;
                    if ((try source.readAt(&dim_buf, dim_off)) == 8) {
                        const w_fp = std.mem.readInt(u32, dim_buf[0..4], .big);
                        const h_fp = std.mem.readInt(u32, dim_buf[4..8], .big);
                        if (w_fp > 0 and width == 0) width = w_fp >> 16;
                        if (h_fp > 0 and height == 0) height = h_fp >> 16;
                    }
                }
            } else if (b.header.fourcc.equals(isobmff.types.BOX_MDHD)) {
                has_mdhd = true;
                if (b.header.payloadSize() >= 20) {
                    var buf: [32]u8 = undefined;
                    const read_n = try source.readAt(&buf, b.header.payloadOffset());
                    if (read_n >= 20) {
                        const version = buf[0];
                        if (version == 1 and read_n >= 32) {
                            timescale = std.mem.readInt(u32, buf[20..24], .big);
                            duration = std.mem.readInt(u64, buf[24..32], .big);
                        } else if (version == 0 and read_n >= 20) {
                            timescale = std.mem.readInt(u32, buf[12..16], .big);
                            duration = std.mem.readInt(u32, buf[16..20], .big);
                        }
                    }
                }
            } else if (b.header.fourcc.equals(isobmff.types.BOX_HDLR)) {
                if (b.header.payloadSize() >= 12) {
                    var buf: [12]u8 = undefined;
                    if ((try source.readAt(&buf, b.header.payloadOffset())) >= 12) {
                        handler_type = FourCC{ .bytes = buf[8..12].* };
                    }
                }
            } else if (b.header.fourcc.equals(isobmff.types.BOX_STSD)) {
                try self.parseStsd(
                    source,
                    b,
                    track_id,
                    issues,
                    &codec_fourcc,
                    &width,
                    &height,
                    &avcc_config,
                    &esds_config,
                );
            } else if (b.header.fourcc.equals(types.BOX_AVCC)) {
                avcc_config = try self.parseAvcC(source, b, track_id, issues);
            } else if (b.header.fourcc.equals(types.BOX_ESDS)) {
                esds_config = try self.parseEsds(source, b, track_id, issues);
            } else if (b.header.fourcc.equals(isobmff.types.BOX_STSZ)) {
                const sz_res = try self.parseStsz(source, b);
                sample_count = sz_res.sample_count;
                total_sample_bytes = sz_res.total_bytes;
            } else if (b.header.fourcc.equals(isobmff.types.BOX_STCO) or b.header.fourcc.equals(isobmff.types.BOX_CO64)) {
                chunk_count = try self.parseChunkCount(source, b);
            } else if (b.header.fourcc.equals(types.CODEC_AVC1) or
                b.header.fourcc.equals(types.CODEC_HVC1) or
                b.header.fourcc.equals(types.CODEC_MP4V))
            {
                codec_fourcc = b.header.fourcc;
                if (b.header.payloadSize() >= 32) {
                    var v_buf: [32]u8 = undefined;
                    if ((try source.readAt(&v_buf, b.header.payloadOffset())) >= 32) {
                        const w = std.mem.readInt(u16, v_buf[24..26], .big);
                        const h = std.mem.readInt(u16, v_buf[26..28], .big);
                        if (w > 0) width = w;
                        if (h > 0) height = h;
                    }
                }
            } else if (b.header.fourcc.equals(types.CODEC_MP4A)) {
                codec_fourcc = types.CODEC_MP4A;
            }
        }

        if (codec_fourcc.equals(types.CODEC_NONE)) {
            codec_fourcc = if (handler_type.equals(types.HANDLER_SOUN))
                types.CODEC_MP4A
            else
                types.CODEC_AVC1;
        }

        const tid = track_id orelse {
            try issues.append(self.allocator, .{
                .code = .track_missing_tkhd,
                .offset = boxes[track_box_idx].header.offset,
                .details = "trak box missing valid tkhd header",
            });
            return null;
        };

        if (!has_mdhd) {
            try issues.append(self.allocator, .{
                .code = .track_missing_mdhd,
                .track_id = tid,
                .offset = boxes[track_box_idx].header.offset,
                .details = "trak box missing mdhd media header",
            });
        }

        return TrackInfo{
            .track_id = tid,
            .handler_type = handler_type,
            .codec_fourcc = codec_fourcc,
            .width = width,
            .height = height,
            .duration = duration,
            .timescale = timescale,
            .sample_count = sample_count,
            .chunk_count = chunk_count,
            .total_sample_bytes = total_sample_bytes,
            .avcc = avcc_config,
            .esds = esds_config,
        };
    }

    fn parseStsd(
        self: Mp4Inspector,
        source: ByteSource,
        box: ParsedBox,
        track_id: ?u32,
        issues: *std.ArrayList(Mp4Issue),
        out_codec: *FourCC,
        out_width: *u32,
        out_height: *u32,
        out_avcc: *?AvcCConfig,
        out_esds: *?EsdsConfig,
    ) !void {
        const payload_size = box.header.payloadSize();
        if (payload_size < 8) return;

        var hdr_buf: [8]u8 = undefined;
        if ((try source.readAt(&hdr_buf, box.header.payloadOffset())) < 8) return;

        const entry_count = std.mem.readInt(u32, hdr_buf[4..8], .big);
        var curr_offset = box.header.payloadOffset() + 8;
        const box_end = box.header.payloadOffset() + payload_size;

        var entry_idx: u32 = 0;
        while (entry_idx < entry_count and curr_offset + 8 <= box_end) : (entry_idx += 1) {
            var entry_hdr: [8]u8 = undefined;
            if ((try source.readAt(&entry_hdr, curr_offset)) < 8) break;

            const entry_size = std.mem.readInt(u32, entry_hdr[0..4], .big);
            const entry_fourcc = FourCC{ .bytes = entry_hdr[4..8].* };

            if (entry_size < 8 or curr_offset + entry_size > box_end) break;

            if (entry_idx == 0) {
                out_codec.* = entry_fourcc;
            }

            // Visual sample entry (e.g. avc1, hvc1, mp4v, etc.)
            // Format: 8 (header) + 6 (reserved) + 2 (data_ref_idx) + 16 (predefined) + 2 (width) + 2 (height) = 36 bytes min
            if (entry_fourcc.equals(types.CODEC_AVC1) or
                entry_fourcc.equals(types.CODEC_AVC3) or
                entry_fourcc.equals(types.CODEC_HVC1) or
                entry_fourcc.equals(types.CODEC_HEV1) or
                entry_fourcc.equals(types.CODEC_MP4V))
            {
                if (entry_size >= 36) {
                    var v_buf: [4]u8 = undefined;
                    if ((try source.readAt(&v_buf, curr_offset + 32)) == 4) {
                        const w = std.mem.readInt(u16, v_buf[0..2], .big);
                        const h = std.mem.readInt(u16, v_buf[2..4], .big);
                        if (w > 0 and out_width.* == 0) out_width.* = w;
                        if (h > 0 and out_height.* == 0) out_height.* = h;
                    }
                }

                // Child boxes inside visual sample entry start at offset 86 (8 header + 78 payload)
                if (entry_size > 86) {
                    var sub_offset = curr_offset + 86;
                    const entry_end = curr_offset + entry_size;
                    while (sub_offset + 8 <= entry_end) {
                        var sub_hdr: [8]u8 = undefined;
                        if ((try source.readAt(&sub_hdr, sub_offset)) < 8) break;
                        const sub_sz = std.mem.readInt(u32, sub_hdr[0..4], .big);
                        const sub_fcc = FourCC{ .bytes = sub_hdr[4..8].* };
                        if (sub_sz < 8 or sub_offset + sub_sz > entry_end) break;

                        if (sub_fcc.equals(types.BOX_AVCC)) {
                            const avcc_b = ParsedBox{
                                .id = 0,
                                .parent_id = null,
                                .depth = 0,
                                .header = .{
                                    .fourcc = types.BOX_AVCC,
                                    .offset = sub_offset,
                                    .size = sub_sz,
                                    .header_size = 8,
                                    .is_extended_size = false,
                                    .is_eof_size = false,
                                },
                                .is_full_box = false,
                                .version = 0,
                                .flags = 0,
                                .role = .metadata,
                            };
                            out_avcc.* = try self.parseAvcC(source, avcc_b, track_id, issues);
                        }

                        sub_offset += sub_sz;
                    }
                }
            } else if (entry_fourcc.equals(types.CODEC_MP4A)) {
                // Audio sample entry: 8 (header) + 28 bytes fixed fields = 36 bytes min
                if (entry_size > 36) {
                    var sub_offset = curr_offset + 36;
                    const entry_end = curr_offset + entry_size;
                    while (sub_offset + 8 <= entry_end) {
                        var sub_hdr: [8]u8 = undefined;
                        if ((try source.readAt(&sub_hdr, sub_offset)) < 8) break;
                        const sub_sz = std.mem.readInt(u32, sub_hdr[0..4], .big);
                        const sub_fcc = FourCC{ .bytes = sub_hdr[4..8].* };
                        if (sub_sz < 8 or sub_offset + sub_sz > entry_end) break;

                        if (sub_fcc.equals(types.BOX_ESDS)) {
                            const esds_b = ParsedBox{
                                .id = 0,
                                .parent_id = null,
                                .depth = 0,
                                .header = .{
                                    .fourcc = types.BOX_ESDS,
                                    .offset = sub_offset,
                                    .size = sub_sz,
                                    .header_size = 8,
                                    .is_extended_size = false,
                                    .is_eof_size = false,
                                },
                                .is_full_box = false,
                                .version = 0,
                                .flags = 0,
                                .role = .metadata,
                            };
                            out_esds.* = try self.parseEsds(source, esds_b, track_id, issues);
                        }

                        sub_offset += sub_sz;
                    }
                }
            }

            curr_offset += entry_size;
        }
    }

    fn parseAvcC(
        self: Mp4Inspector,
        source: ByteSource,
        box: ParsedBox,
        track_id: ?u32,
        issues: *std.ArrayList(Mp4Issue),
    ) !?AvcCConfig {
        const payload_size = box.header.payloadSize();
        if (payload_size < 7) return null;

        var buf: [64]u8 = undefined;
        const read_n = try source.readAt(&buf, box.header.payloadOffset());
        if (read_n < 7) return null;

        const config_version = buf[0];
        if (config_version != 1) {
            try issues.append(self.allocator, .{
                .code = .avcc_invalid_version,
                .track_id = track_id,
                .offset = box.header.offset,
                .details = "avcC configurationVersion != 1",
            });
        }

        const profile = buf[1];
        const compat = buf[2];
        const level = buf[3];
        const length_size_minus_one: u2 = @truncate(buf[4] & 0x03);
        const num_sps = buf[5] & 0x1F;

        var cursor: usize = 6;
        var sps_bytes_total: u32 = 0;

        var i: u8 = 0;
        while (i < num_sps and cursor + 2 <= read_n) : (i += 1) {
            const sps_len = std.mem.readInt(u16, buf[cursor..][0..2], .big);
            cursor += 2;
            if (cursor + sps_len > payload_size) {
                try issues.append(self.allocator, .{
                    .code = .avcc_sps_length_overflow,
                    .track_id = track_id,
                    .offset = box.header.offset,
                    .details = "SPS length exceeds avcC box boundaries",
                });
                break;
            }
            sps_bytes_total += sps_len;
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
                if (cursor + pps_len > payload_size) {
                    try issues.append(self.allocator, .{
                        .code = .avcc_pps_length_overflow,
                        .track_id = track_id,
                        .offset = box.header.offset,
                        .details = "PPS length exceeds avcC box boundaries",
                    });
                    break;
                }
                pps_bytes_total += pps_len;
                cursor += pps_len;
            }
        }

        return AvcCConfig{
            .configuration_version = config_version,
            .profile_indication = profile,
            .profile_compatibility = compat,
            .level_indication = level,
            .length_size_minus_one = length_size_minus_one,
            .sps_count = num_sps,
            .pps_count = num_pps,
            .sps_bytes_total = sps_bytes_total,
            .pps_bytes_total = pps_bytes_total,
        };
    }

    fn parseEsds(
        self: Mp4Inspector,
        source: ByteSource,
        box: ParsedBox,
        track_id: ?u32,
        issues: *std.ArrayList(Mp4Issue),
    ) !?EsdsConfig {
        const payload_size = box.header.payloadSize();
        if (payload_size < 12) return null;

        var buf: [128]u8 = undefined;
        const read_n = try source.readAt(&buf, box.header.payloadOffset());
        if (read_n < 12) return null;

        // Skip 4-byte FullBox header (version + flags)
        var cursor: usize = 4;
        var res = EsdsConfig{};

        // Expect Tag 0x03 (ES_DescrTag)
        if (cursor < read_n and buf[cursor] == 0x03) {
            cursor += 1;
            const es_len = decodeTlvLength(buf[0..read_n], &cursor) orelse {
                try issues.append(self.allocator, .{
                    .code = .esds_tlv_length_overflow,
                    .track_id = track_id,
                    .offset = box.header.offset,
                    .details = "esds ES_Descriptor TLV length overflow",
                });
                return null;
            };
            if (cursor + es_len > payload_size) {
                try issues.append(self.allocator, .{
                    .code = .esds_tlv_length_overflow,
                    .track_id = track_id,
                    .offset = box.header.offset,
                    .details = "esds ES_Descriptor exceeds box boundary",
                });
            }

            if (cursor + 3 <= read_n) {
                res.es_id = std.mem.readInt(u16, buf[cursor..][0..2], .big);
                cursor += 3; // ES_ID (2) + streamPriority (1)
            }
        }

        // Expect Tag 0x04 (DecoderConfigDescrTag)
        if (cursor < read_n and buf[cursor] == 0x04) {
            cursor += 1;
            _ = decodeTlvLength(buf[0..read_n], &cursor);
            if (cursor + 13 <= read_n) {
                res.object_type_indication = buf[cursor];
                res.stream_type = buf[cursor + 1] >> 2;
                res.buffer_size_db = (@as(u24, buf[cursor + 2]) << 16) | (@as(u24, buf[cursor + 3]) << 8) | buf[cursor + 4];
                res.max_bitrate = std.mem.readInt(u32, buf[cursor + 5 ..][0..4], .big);
                res.avg_bitrate = std.mem.readInt(u32, buf[cursor + 9 ..][0..4], .big);
            }
        }

        return res;
    }

    const StszResult = struct {
        sample_count: u32,
        total_bytes: u64,
    };

    fn parseStsz(self: Mp4Inspector, source: ByteSource, box: ParsedBox) !StszResult {
        _ = self;
        if (box.header.payloadSize() < 12) return .{ .sample_count = 0, .total_bytes = 0 };

        var buf: [12]u8 = undefined;
        if ((try source.readAt(&buf, box.header.payloadOffset())) < 12) {
            return .{ .sample_count = 0, .total_bytes = 0 };
        }

        const uniform_size = std.mem.readInt(u32, buf[4..8], .big);
        const sample_count = std.mem.readInt(u32, buf[8..12], .big);

        if (uniform_size > 0) {
            return .{
                .sample_count = sample_count,
                .total_bytes = @as(u64, uniform_size) * @as(u64, sample_count),
            };
        }

        // If uniform_size == 0, read table entries to accumulate total bytes
        var total_bytes: u64 = 0;
        const entry_offset = box.header.payloadOffset() + 12;
        var batch_buf: [1024]u8 = undefined; // 256 entries per batch

        var processed: u32 = 0;
        while (processed < sample_count) {
            const batch_count: usize = @min(@as(usize, sample_count - processed), 256);
            const batch_bytes: usize = batch_count * 4;
            const entry_curr_offset = entry_offset + (@as(u64, processed) * 4);
            const read_n = try source.readAt(batch_buf[0..batch_bytes], entry_curr_offset);
            if (read_n < batch_bytes) break;

            var k: usize = 0;
            while (k < batch_count) : (k += 1) {
                const s = std.mem.readInt(u32, batch_buf[k * 4 ..][0..4], .big);
                total_bytes += s;
            }
            processed += @intCast(batch_count);
        }

        return .{
            .sample_count = sample_count,
            .total_bytes = total_bytes,
        };
    }

    fn parseChunkCount(self: Mp4Inspector, source: ByteSource, box: ParsedBox) !u32 {
        _ = self;
        if (box.header.payloadSize() < 8) return 0;
        var buf: [8]u8 = undefined;
        if ((try source.readAt(&buf, box.header.payloadOffset())) < 8) return 0;
        return std.mem.readInt(u32, buf[4..8], .big);
    }
};

fn isDescendantOf(boxes: []const ParsedBox, child: ParsedBox, ancestor_idx: u32) bool {
    var curr_parent = child.parent_id;
    while (curr_parent) |pid| {
        if (pid == ancestor_idx) return true;
        if (pid >= boxes.len) break;
        curr_parent = boxes[pid].parent_id;
    }
    return false;
}

fn decodeTlvLength(buf: []const u8, cursor: *usize) ?u32 {
    var len: u32 = 0;
    var count: u8 = 0;
    while (cursor.* < buf.len and count < 4) : (count += 1) {
        const b = buf[cursor.*];
        cursor.* += 1;
        len = (len << 7) | (b & 0x7F);
        if ((b & 0x80) == 0) return len;
    }
    return null;
}
