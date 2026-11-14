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
    has_ftyp: bool,
    major_brand: []const u8,
    ftyp_valid: bool,
};

pub const OutputsData = struct {
    mp4_ftyp_check: CheckRow,
    audit_findings: []const media_ir.AuditFindingRow,
};

pub const Outputs = abi.Channels(OutputsData);

/// Atomic ISOBMFF check: validates `ftyp` presence, truncation, and recognized major brand before IR lowering.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        const parsed = try isobmff.box.SafeBoxParser.init(alloc).parse(source);
        defer parsed.deinit(alloc);

        const inspector = isobmff.mp4.Mp4Inspector.init(alloc);
        var issues = std.ArrayList(isobmff.mp4.Mp4Issue).empty;
        defer issues.deinit(alloc);

        var major_brand: []const u8 = "none";
        var has_ftyp = false;

        for (parsed.boxes) |b| {
            if (b.header.fourcc.equals(isobmff.box.types.BOX_FTYP)) {
                has_ftyp = true;
                const ftyp = try inspector.parseFtyp(source, b, &issues);
                defer alloc.free(ftyp.compatible_brands);
                major_brand = try alloc.dupe(u8, &ftyp.major_brand.bytes);
                break;
            }
        }

        const findings = try common.collectFindings(alloc, &.{}, &.{}, &.{}, issues.items);
        const valid = has_ftyp and issues.items.len == 0;

        return .{ .data = .{
            .mp4_ftyp_check = .{
                .has_ftyp = has_ftyp,
                .major_brand = major_brand,
                .ftyp_valid = valid,
            },
            .audit_findings = findings,
        } };
    }
};
