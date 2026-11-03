const std = @import("std");
const abi = @import("vidsec_abi");
const ir = @import("vidsec_ir");
const strategy_mod = @import("strategy.zig");
const SampleLoweringStrategy = strategy_mod.SampleLoweringStrategy;

fn nextSampleRow(ctx: abi.TaskContext) abi.SdkError!?abi.RowView_ABI {
    if (ctx.nextRow("samples")) |maybe_row| {
        return maybe_row;
    } else |err| {
        if (err == error.NotFound) {
            if (ctx.nextRow("sample_extents")) |alt_row| {
                return alt_row;
            } else |alt_err| {
                if (alt_err == error.NotFound) return null;
                return alt_err;
            }
        }
        return err;
    }
}

/// Explicit implementation of `SampleLoweringStrategy`.
pub const DefaultSampleStrategy = struct {
    comptime {
        SampleLoweringStrategy.assertImplements(@This());
    }

    pub fn lowerSamples(ctx: abi.TaskContext) abi.SdkError!void {
        var extent_id: i64 = 1;
        while (try nextSampleRow(ctx)) |sample_row| {
            const track_id = if (sample_row.getField("track_id")) |v| v.asInt() orelse 1 else 1;
            const sample_index = if (sample_row.getField("sample_index")) |v| v.asInt() orelse extent_id else extent_id;
            const source_tag = if (sample_row.getField("source_tag")) |v| v.asText() orelse "mdat" else "mdat";
            const target_offset = if (sample_row.getField("target_offset")) |v| v.asInt() orelse 0 else 0;
            const byte_size = if (sample_row.getField("byte_size")) |v| v.asInt() orelse 0 else 0;
            const end_offset = target_offset + byte_size;

            try ir.emitIrSampleExtent(ctx, .{
                .extent_id = extent_id,
                .track_id = track_id,
                .sample_index = sample_index,
                .source_tag = source_tag,
                .target_offset = @intCast(@max(0, target_offset)),
                .byte_size = @intCast(@max(0, byte_size)),
                .end_offset = @intCast(@max(0, end_offset)),
            });
            extent_id += 1;
        }
    }

    pub const strategy: SampleLoweringStrategy = .{
        .lower_samples = &lowerSamples,
    };
};

pub const lowerSampleExtents = DefaultSampleStrategy.lowerSamples;
