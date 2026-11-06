const std = @import("std");
const ir = @import("vidsec_ir");
const strategy_mod = @import("strategy.zig");
const SampleLoweringStrategy = strategy_mod.SampleLoweringStrategy;
const SampleInput = strategy_mod.SampleInput;

/// Explicit implementation of `SampleLoweringStrategy`.
pub const DefaultSampleStrategy = struct {
    comptime {
        SampleLoweringStrategy.assertImplements(@This());
    }

    pub fn lowerSamples(
        allocator: std.mem.Allocator,
        samples: []const SampleInput,
        extent_counter: *i64,
    ) anyerror![]ir.IrSampleExtentRow {
        var list = std.ArrayList(ir.IrSampleExtentRow).empty;
        errdefer list.deinit(allocator);

        for (samples) |s| {
            const end_offset = s.target_offset + s.byte_size;
            try list.append(allocator, .{
                .extent_id = extent_counter.*,
                .track_id = s.track_id,
                .sample_index = s.sample_index,
                .source_tag = s.source_tag,
                .target_offset = s.target_offset,
                .byte_size = s.byte_size,
                .end_offset = end_offset,
            });
            extent_counter.* += 1;
        }

        return try list.toOwnedSlice(allocator);
    }

    pub const strategy: SampleLoweringStrategy = .{
        .lower_samples = &lowerSamples,
    };
};

pub const lowerSampleExtents = DefaultSampleStrategy.lowerSamples;
