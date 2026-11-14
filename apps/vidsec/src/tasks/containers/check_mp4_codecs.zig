const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const isobmff = @import("isobmff");
const media_ir = @import("media_ir");
const common = @import("common.zig");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
};

pub const CheckRow = struct {
    avcc_count: u64,
    esds_count: u64,
    codec_config_valid: bool,
};

pub const OutputsData = struct {
    mp4_codecs_check: CheckRow,
    audit_findings: []const media_ir.AuditFindingRow,
};

pub const Outputs = abi.Channels(OutputsData);

const BOX_AVCC = isobmff.box.FourCC.init("avcC");
const BOX_ESDS = isobmff.box.FourCC.init("esds");

/// Atomic ISOBMFF CVE guard: validates `avcC` (SPS/PPS length overflows) and `esds` (TLV overflows) before IR lowering.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        const parsed = try isobmff.box.SafeBoxParser.init(alloc).parse(source);
        defer parsed.deinit(alloc);

        const inspector = isobmff.mp4.Mp4Inspector.init(alloc);
        var issues = std.ArrayList(isobmff.mp4.Mp4Issue).empty;
        defer issues.deinit(alloc);

        var avcc_count: u64 = 0;
        var esds_count: u64 = 0;

        for (parsed.boxes) |b| {
            if (b.header.fourcc.equals(BOX_AVCC)) {
                avcc_count += 1;
                _ = try inspector.parseAvcC(source, b, null, &issues);
            } else if (b.header.fourcc.equals(BOX_ESDS)) {
                esds_count += 1;
                _ = try inspector.parseEsds(source, b, null, &issues);
            }
        }

        const findings = try common.collectFindings(alloc, &.{}, &.{}, &.{}, issues.items);

        return .{ .data = .{
            .mp4_codecs_check = .{
                .avcc_count = avcc_count,
                .esds_count = esds_count,
                .codec_config_valid = issues.items.len == 0,
            },
            .audit_findings = findings,
        } };
    }
};

