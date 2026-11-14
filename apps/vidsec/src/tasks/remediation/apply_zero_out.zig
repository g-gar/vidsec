const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");
const orders = @import("orders.zig");

pub const DEFAULT_MAX_IN_MEMORY_BYTES: u64 = 64 * 1024 * 1024;

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
    offset: u64,
    length: u64,
    rule_id: []const u8,
    reason: []const u8 = "",
    max_in_memory_bytes: u64 = DEFAULT_MAX_IN_MEMORY_BYTES,
};

pub const Outputs = orders.RemediationOutcome;

/// Subscribes to `ZeroOutOrder` + stream and emits a sanitized byte slice with
/// `[offset, offset + length)` overwritten with `0x00` for any pipeline sink.
pub const Service = struct {
    pub fn execute(_: *const Service, alloc: Allocator, inputs: Inputs) !Outputs {
        const current_size = inputs.stream.len();
        if (current_size > inputs.max_in_memory_bytes) {
            return error.StreamExceedsInMemoryLimit;
        }
        const bounded_offset = @min(inputs.offset, current_size);
        const max_len = current_size - bounded_offset;
        const effective_len = @min(inputs.length, max_len);
        const should_apply = effective_len > 0;

        const total_len: usize = @intCast(current_size);
        const buf = try alloc.alloc(u8, total_len);
        if (total_len > 0) {
            try inputs.stream.readAt(0, buf);
        }

        if (should_apply) {
            const start: usize = @intCast(bounded_offset);
            const len: usize = @intCast(effective_len);
            @memset(buf[start .. start + len], 0);
        }

        return .{
            .data = buf,
            .action = "zero_out",
            .rule_id = inputs.rule_id,
            .offset = bounded_offset,
            .length = effective_len,
            .new_size = current_size,
            .applied = should_apply,
            .requires_reverify = should_apply,
        };
    }
};
