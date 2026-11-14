const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const orders = @import("orders.zig");

pub const DEFAULT_MAX_IN_MEMORY_BYTES: u64 = 64 * 1024 * 1024;

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
    new_size: u64,
    rule_id: []const u8,
    reason: []const u8 = "",
    max_in_memory_bytes: u64 = DEFAULT_MAX_IN_MEMORY_BYTES,
};

pub const Outputs = orders.RemediationOutcome;

/// Subscribes to `TruncateOrder` + stream and emits the truncated byte slice
/// for the pipeline to route to any configured sink.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const current_size = inputs.stream.len();
        const effective_size = @min(inputs.new_size, current_size);
        if (effective_size > inputs.max_in_memory_bytes) {
            return error.StreamExceedsInMemoryLimit;
        }
        const should_apply = effective_size < current_size;

        const out_len: usize = @intCast(effective_size);
        const buf = try alloc.alloc(u8, out_len);
        if (out_len > 0) {
            try inputs.stream.readAt(0, buf);
        }

        return .{
            .data = buf,
            .action = "truncate",
            .rule_id = inputs.rule_id,
            .offset = effective_size,
            .length = if (should_apply) current_size - effective_size else 0,
            .new_size = effective_size,
            .applied = should_apply,
            .requires_reverify = should_apply,
        };
    }
};
