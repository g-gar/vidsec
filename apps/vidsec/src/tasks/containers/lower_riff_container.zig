const std = @import("std");
const Allocator = std.mem.Allocator;
const riff = @import("riff");
const media_ir = @import("media_ir");
const common = @import("common.zig");

pub const Inputs = common.ContainerInputs;
pub const Outputs = common.ContainerOutputs;

const inline_checks = [_]media_ir.common.InLineCheck{
    .{ .run_fn = riff.riff.checks.checkChunkOverflow },
};

/// Parses RIFF/AVI chunks in O(chunks), runs in-line structural checks,
/// and lowers the container into `media_ir` regions and audit findings.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const source = common.streamToByteSource(&inputs.stream);
        const parser = riff.riff.SafeRiffParser.init(alloc, .{});
        var diagnostics = media_ir.common.DiagnosticList.init();
        defer diagnostics.deinit(alloc);

        const parsed = try parser.parseWithDiagnostics(source, &inline_checks, &diagnostics);
        defer parsed.deinit(alloc);

        const regions = try riff.riff.toRegions(parsed.chunks, alloc);
        defer alloc.free(regions);

        const region_inputs = try common.regionsToInputs(alloc, regions);
        const lowered = try riff.lowerContainer(
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
