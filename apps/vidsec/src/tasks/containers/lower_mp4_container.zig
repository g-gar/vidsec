const std = @import("std");
const Allocator = std.mem.Allocator;
const isobmff = @import("isobmff");
const media_ir = @import("media_ir");
const common = @import("common.zig");

pub const Inputs = common.ContainerInputs;
pub const Outputs = common.ContainerOutputs;

const inline_checks = [_]media_ir.common.InLineCheck{
    .{ .run_fn = isobmff.box.checks.checkBoxMinSize },
    .{ .run_fn = isobmff.box.checks.checkBoxOverflow },
    .{ .run_fn = isobmff.box.checks.checkFourccPrintable },
    .{ .run_fn = isobmff.box.checks.checkNestingBoundary },
};

/// Parses ISOBMFF/MP4 boxes in O(boxes), runs in-line structural checks and `Mp4Inspector`,
/// and lowers the container into `media_ir` regions and audit findings.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        const parser = isobmff.box.SafeBoxParser.init(alloc);
        var diagnostics = media_ir.common.DiagnosticList.init();
        defer diagnostics.deinit(alloc);

        const parsed = try parser.parseWithDiagnostics(source, &inline_checks, &diagnostics);
        defer parsed.deinit(alloc);

        const regions = try isobmff.box.toRegions(parsed.boxes, alloc);
        defer alloc.free(regions);

        const region_inputs = try common.regionsToInputs(alloc, regions);
        const lowered = try isobmff.lowerContainer(
            alloc,
            @intCast(inputs.stream.len()),
            inputs.true_magic_kind,
            inputs.identified_format,
            region_inputs,
        );

        const findings = try common.collectFindings(
            alloc,
            lowered.overflow_findings,
            parsed.issues,
            diagnostics.items.items,
            &.{},
        );

        return .{ .data = .{
            .container_metadata = lowered.metadata,
            .ir_regions = lowered.regions,
            .audit_findings = findings,
        } };
    }
};
