const std = @import("std");
const abi = @import("vidsec_abi");
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

            const fields = [_]abi.NamedField_ABI{
                abi.NamedField_ABI.init("extent_id", abi.Value_ABI.fromInt(extent_id)),
                abi.NamedField_ABI.init("track_id", abi.Value_ABI.fromInt(track_id)),
                abi.NamedField_ABI.init("sample_index", abi.Value_ABI.fromInt(sample_index)),
                abi.NamedField_ABI.init("source_tag", abi.Value_ABI.fromText(source_tag)),
                abi.NamedField_ABI.init("target_offset", abi.Value_ABI.fromInt(target_offset)),
                abi.NamedField_ABI.init("byte_size", abi.Value_ABI.fromInt(byte_size)),
                abi.NamedField_ABI.init("end_offset", abi.Value_ABI.fromInt(end_offset)),
            };

            try ctx.emitRow("ir_sample_extents", &fields);
            extent_id += 1;
        }
    }

    pub const strategy: SampleLoweringStrategy = .{
        .lower_samples = &lowerSamples,
    };
};

pub const lowerSampleExtents = DefaultSampleStrategy.lowerSamples;
