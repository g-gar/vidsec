const std = @import("std");
const abi = @import("flowdata_abi");
const vidsec = @import("vidsec");

const lower_mp4 = vidsec.tasks.lower_mp4_container;
const lower_ebml = vidsec.tasks.lower_ebml_container;
const lower_riff = vidsec.tasks.lower_riff_container;
const check_mp4_ftyp = vidsec.tasks.check_mp4_ftyp;
const check_mp4_codecs = vidsec.tasks.check_mp4_codecs;
const check_mp4_tracks = vidsec.tasks.check_mp4_tracks;
const check_ebml_header = vidsec.tasks.check_ebml_header;
const check_mkv_tracks = vidsec.tasks.check_mkv_tracks;
const check_riff_chunks = vidsec.tasks.check_riff_chunks;

const SliceStreamHost = struct {
    data: []const u8,
    ctx_abi: abi.TaskContext_ABI = undefined,
    vtable: abi.HostApiVTable_ABI = undefined,

    fn init(data: []const u8) SliceStreamHost {
        var self = SliceStreamHost{ .data = data };
        self.vtable = std.mem.zeroes(abi.HostApiVTable_ABI);
        self.vtable.stream_size = &streamSize;
        self.vtable.stream_read_at = &streamReadAt;
        self.ctx_abi = .{
            .abi_version = abi.FLOWDATA_ABI_VERSION,
            .host = &self.vtable,
            .opaque_host_state = &self,
        };
        return self;
    }

    fn reader(self: *SliceStreamHost) abi.BoundedStreamReader {
        self.ctx_abi.host = &self.vtable;
        self.ctx_abi.opaque_host_state = self;
        const ctx = abi.TaskContext.init(&self.ctx_abi);
        return ctx.streamReader();
    }

    fn streamSize(raw: *abi.TaskContext_ABI) callconv(.c) u64 {
        const self: *const SliceStreamHost = @ptrCast(@alignCast(raw.opaque_host_state));
        return self.data.len;
    }

    fn streamReadAt(raw: *abi.TaskContext_ABI, offset: u64, dest_ptr: [*]u8, len: usize) callconv(.c) abi.HostError_ABI {
        const self: *const SliceStreamHost = @ptrCast(@alignCast(raw.opaque_host_state));
        if (offset + len > self.data.len) return .end_of_stream;
        @memcpy(dest_ptr[0..len], self.data[@intCast(offset)..][0..len]);
        return .ok;
    }
};

test "lower_mp4_container lowers ftyp + moov + mdat in O(boxes)" {
    // 24-byte ftyp + 8-byte moov + 16-byte mdat = 48 bytes
    const data =
        "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isommp41" ++
        "\x00\x00\x00\x08moov" ++
        "\x00\x00\x00\x10mdat\xDE\xAD\xBE\xEF\xCA\xFE\xBA\xBE";

    var host = SliceStreamHost.init(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const svc = lower_mp4.Service{};
    const out = (try svc.execute(arena.allocator(), .{
        .stream = host.reader(),
        .true_magic_kind = 10,
        .identified_format = "mp4",
    })).data;

    try std.testing.expectEqual(@as(u64, data.len), out.container_metadata.file_size);
    try std.testing.expectEqual(@as(u64, data.len), out.container_metadata.highest_root_end);
    try std.testing.expectEqual(@as(i64, 10), out.container_metadata.true_magic);
    try std.testing.expectEqualStrings("mp4", out.container_metadata.true_magic_name);
    try std.testing.expectEqual(@as(usize, 3), out.ir_regions.len);
    try std.testing.expectEqualStrings("ftyp", out.ir_regions[0].tag_name);
    try std.testing.expectEqualStrings("moov", out.ir_regions[1].tag_name);
    try std.testing.expectEqualStrings("mdat", out.ir_regions[2].tag_name);
    try std.testing.expectEqualStrings("media_data", out.ir_regions[2].role);
    try std.testing.expectEqual(@as(usize, 0), out.audit_findings.len);
}

test "lower_mp4_container flags overflowing mdat box" {
    // ftyp (24) + moov (8) + mdat declaring 100 bytes when only 12 remain
    const data =
        "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isommp41" ++
        "\x00\x00\x00\x08moov" ++
        "\x00\x00\x00\x64mdat\x00\x01\x02\x03";

    var host = SliceStreamHost.init(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const svc = lower_mp4.Service{};
    const out = (try svc.execute(arena.allocator(), .{
        .stream = host.reader(),
    })).data;

    try std.testing.expectEqual(@as(usize, 3), out.ir_regions.len);
    try std.testing.expect(out.ir_regions[2].is_truncated_or_overflow);
    try std.testing.expect(out.audit_findings.len >= 1);
}

test "lower_ebml_container lowers EBML header + Segment + Cluster" {
    // EBML Header (0x1A45DFA3, size 4 -> 0x84, 4 dummy bytes) = 9 bytes
    // Segment (0x18538067, size 10 -> 0x8A) containing Cluster (0x1F43B675, size 5 -> 0x85, 5 bytes) = 15 bytes
    const data =
        "\x1A\x45\xDF\xA3\x84\x42\x86\x81\x01" ++
        "\x18\x53\x80\x67\x8A" ++
        "\x1F\x43\xB6\x75\x85\x01\x02\x03\x04\x05";

    var host = SliceStreamHost.init(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const svc = lower_ebml.Service{};
    const out = (try svc.execute(arena.allocator(), .{
        .stream = host.reader(),
        .true_magic_kind = 11,
        .identified_format = "mkv",
    })).data;

    try std.testing.expectEqual(@as(u64, data.len), out.container_metadata.file_size);
    try std.testing.expectEqual(@as(u64, data.len), out.container_metadata.highest_root_end);
    try std.testing.expect(out.ir_regions.len >= 2);
    try std.testing.expectEqualStrings("0x1a45dfa3", out.ir_regions[0].tag_name);
}

test "lower_riff_container lowers RIFF/AVI + LIST hdrl + LIST movi" {
    // RIFF (size=28: "AVI " (4) + LIST hdrl (12) + LIST movi (12)) -> total 36 bytes
    const data =
        "RIFF\x1C\x00\x00\x00AVI " ++
        "LIST\x04\x00\x00\x00hdrl" ++
        "LIST\x04\x00\x00\x00movi";

    var host = SliceStreamHost.init(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const svc = lower_riff.Service{};
    const out = (try svc.execute(arena.allocator(), .{
        .stream = host.reader(),
        .true_magic_kind = 12,
        .identified_format = "avi",
    })).data;

    try std.testing.expectEqual(@as(u64, data.len), out.container_metadata.file_size);
    try std.testing.expectEqual(@as(u64, data.len), out.container_metadata.highest_root_end);
    try std.testing.expect(out.ir_regions.len >= 2);
    try std.testing.expectEqualStrings("RIFF", out.ir_regions[0].tag_name);
    try std.testing.expectEqual(@as(usize, 0), out.audit_findings.len);
}

test "check_mp4_ftyp validates ftyp brand independently" {
    const data =
        "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isommp41" ++
        "\x00\x00\x00\x08moov";

    var host = SliceStreamHost.init(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const svc = check_mp4_ftyp.Service{};
    const out = (try svc.execute(arena.allocator(), .{
        .stream = host.reader(),
    })).data;

    try std.testing.expect(out.mp4_ftyp_check.has_ftyp);
    try std.testing.expectEqualStrings("isom", out.mp4_ftyp_check.major_brand);
    try std.testing.expect(out.mp4_ftyp_check.ftyp_valid);
}

test "check_mp4_codecs catches avcC SPS overflow CVE pattern" {
    // ftyp (24) + avcC (16 bytes total: 8-byte box hdr + 8-byte avcC declaring num_sps=1, sps_len=200 > payload)
    const data =
        "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isommp41" ++
        "\x00\x00\x00\x10avcC\x01\x42\x00\x1E\xFF\xE1\x00\xC8";

    var host = SliceStreamHost.init(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const svc = check_mp4_codecs.Service{};
    const out = (try svc.execute(arena.allocator(), .{
        .stream = host.reader(),
    })).data;

    try std.testing.expectEqual(@as(u64, 1), out.mp4_codecs_check.avcc_count);
    try std.testing.expect(!out.mp4_codecs_check.codec_config_valid);
    try std.testing.expectEqualStrings("avcc_sps_length_overflow", out.audit_findings[0].rule_id);
}

test "check_mp4_tracks validates track hierarchy and mdat slack independently" {
    const data =
        "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isommp41" ++
        "\x00\x00\x00\x08moov" ++
        "\x00\x00\x00\x10mdat\xDE\xAD\xBE\xEF\xCA\xFE\xBA\xBE";

    var host = SliceStreamHost.init(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const svc = check_mp4_tracks.Service{};
    const out = (try svc.execute(arena.allocator(), .{
        .stream = host.reader(),
    })).data;

    try std.testing.expectEqual(@as(u64, 0), out.mp4_tracks_check.track_count);
    try std.testing.expect(out.mp4_tracks_check.tracks_valid);
}

test "check_ebml_header and check_mkv_tracks validate EBML/MKV independently" {
    const data =
        "\x1A\x45\xDF\xA3\x84\x42\x86\x81\x01" ++
        "\x18\x53\x80\x67\x8A" ++
        "\x1F\x43\xB6\x75\x85\x01\x02\x03\x04\x05";

    var host = SliceStreamHost.init(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const hdr_out = (try (check_ebml_header.Service{}).execute(arena.allocator(), .{
        .stream = host.reader(),
    })).data;
    try std.testing.expect(hdr_out.ebml_header_check.has_ebml_header);
    try std.testing.expect(hdr_out.ebml_header_check.has_segment);
    try std.testing.expectEqual(@as(u64, 1), hdr_out.ebml_header_check.cluster_count);
    try std.testing.expect(hdr_out.ebml_header_check.ebml_valid);

    const trk_out = (try (check_mkv_tracks.Service{}).execute(arena.allocator(), .{
        .stream = host.reader(),
    })).data;
    try std.testing.expect(!trk_out.mkv_tracks_check.tracks_valid);
    try std.testing.expectEqualStrings("segment_missing_tracks", trk_out.audit_findings[0].rule_id);
}

test "check_riff_chunks validates RIFF/AVI structure independently" {
    const data =
        "RIFF\x1C\x00\x00\x00AVI " ++
        "LIST\x04\x00\x00\x00hdrl" ++
        "LIST\x04\x00\x00\x00movi";

    var host = SliceStreamHost.init(data);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const out = (try (check_riff_chunks.Service{}).execute(arena.allocator(), .{
        .stream = host.reader(),
    })).data;

    try std.testing.expectEqualStrings("AVI ", out.riff_chunks_check.form_type);
    try std.testing.expectEqual(@as(u64, 28), out.riff_chunks_check.root_size);
    try std.testing.expect(out.riff_chunks_check.riff_valid);
}
