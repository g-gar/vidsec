const std = @import("std");
const abi = @import("flowdata_abi");
const vidsec = @import("vidsec");

const check_file_size = vidsec.tasks.check_file_size;
const detect_magic = vidsec.tasks.detect_magic;
const check_extension = vidsec.tasks.check_extension;
const scan_head_executables = vidsec.tasks.scan_head_executables;
const scan_tail_archives = vidsec.tasks.scan_tail_archives;
const measure_mid_entropy = vidsec.tasks.measure_mid_entropy;

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

test "check_file_size enforces min and max bounds" {
    const svc = check_file_size.Service{};

    const small: [4]u8 = @splat(0);
    var small_host = SliceStreamHost.init(&small);
    const small_out = try svc.execute(.{
        .stream = small_host.reader(),
        .min_file_size_bytes = 8,
    });
    try std.testing.expectEqual(@as(u64, 4), small_out.file_size);
    try std.testing.expect(small_out.below_min_size);
    try std.testing.expect(!small_out.size_valid);

    const ok_buf: [64]u8 = @splat(0);
    var ok_host = SliceStreamHost.init(&ok_buf);
    const ok_out = try svc.execute(.{
        .stream = ok_host.reader(),
        .min_file_size_bytes = 8,
    });
    try std.testing.expect(ok_out.size_valid);
}

test "detect_magic identifies valid MP4 and hostile ELF" {
    const svc = detect_magic.Service{};

    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    var mp4_host = SliceStreamHost.init(mp4_hdr);
    const mp4_out = try svc.execute(.{ .stream = mp4_host.reader() });
    try std.testing.expectEqualStrings("isobmff", mp4_out.detected_family);
    try std.testing.expectEqualStrings("mp4", mp4_out.identified_format);
    try std.testing.expectEqualStrings("mp4", mp4_out.canonical_extension);
    try std.testing.expectEqualStrings("video/mp4", mp4_out.mime_type);
    try std.testing.expect(mp4_out.is_video);
    try std.testing.expect(!mp4_out.is_hostile);

    var elf_buf: [64]u8 = @splat(0);
    @memcpy(elf_buf[0..4], "\x7FELF");
    var elf_host = SliceStreamHost.init(&elf_buf);
    const elf_out = try svc.execute(.{ .stream = elf_host.reader() });
    try std.testing.expectEqualStrings("unknown", elf_out.detected_family);
    try std.testing.expectEqualStrings("elf", elf_out.identified_format);
    try std.testing.expect(!elf_out.is_video);
    try std.testing.expect(elf_out.is_hostile);
}

test "check_extension validates matching and spoofed extensions" {
    const svc = check_extension.Service{};

    const match_out = try svc.execute(.{
        .identified_format = "mp4",
        .canonical_extension = "mp4",
        .declared_extension = "clip.MP4",
        .strict_extension = true,
    });
    try std.testing.expect(match_out.extension_match);
    try std.testing.expect(!match_out.extension_violation);

    const mismatch_out = try svc.execute(.{
        .identified_format = "elf",
        .canonical_extension = "elf",
        .declared_extension = "evil.mp4",
        .strict_extension = true,
    });
    try std.testing.expect(!mismatch_out.extension_match);
    try std.testing.expect(mismatch_out.extension_violation);
}

test "scan_head_executables detects primary and embedded MZ/ELF" {
    const svc = scan_head_executables.Service{};

    var buf: [128]u8 = @splat(0);
    @memcpy(buf[32..36], "\x7FELF");
    var host = SliceStreamHost.init(&buf);

    const out = try svc.execute(.{ .stream = host.reader() });
    try std.testing.expect(!out.primary_at_zero);
    try std.testing.expectEqual(@as(?u64, 32), out.secondary_offset);
    try std.testing.expect(out.has_embedded_executable);
}

test "scan_tail_archives detects appended ZIP EOCD" {
    const svc = scan_tail_archives.Service{};

    var buf: [256]u8 = @splat(0);
    @memcpy(buf[230..234], "PK\x05\x06");
    var host = SliceStreamHost.init(&buf);

    const out = try svc.execute(.{ .stream = host.reader() });
    try std.testing.expect(out.has_tail_polyglot);
    try std.testing.expectEqual(@as(?u64, 230), out.zip_eocd_offset);
}

test "measure_mid_entropy distinguishes zero-filled vs random streams" {
    const svc = measure_mid_entropy.Service{};

    const zeros: [1024]u8 = @splat(0);
    var zero_host = SliceStreamHost.init(&zeros);
    const zero_out = try svc.execute(.{ .stream = zero_host.reader() });
    try std.testing.expectEqual(@as(f64, 0.0), zero_out.mid_entropy);
    try std.testing.expect(zero_out.low_mid_entropy);

    var rand_buf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(77);
    prng.random().bytes(&rand_buf);
    var rand_host = SliceStreamHost.init(&rand_buf);
    const rand_out = try svc.execute(.{ .stream = rand_host.reader() });
    try std.testing.expect(rand_out.mid_entropy > 7.0);
    try std.testing.expect(!rand_out.low_mid_entropy);
}
