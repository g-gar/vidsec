const std = @import("std");
const abi = @import("flowdata_abi");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
    min_file_size_bytes: i64 = 8,
    max_file_size_mb: i64 = 4096,
};

pub const Outputs = struct {
    file_size: u64,
    below_min_size: bool,
    exceeds_size_limit: bool,
    size_valid: bool,
};

/// Validates stream byte length against `[min_file_size_bytes, max_file_size_mb]` without reading stream bytes.
pub const Service = struct {
    pub fn execute(_: *const Service, inputs: Inputs) !Outputs {
        const file_size = inputs.stream.len();
        const min_bytes: u64 = if (inputs.min_file_size_bytes > 0) @intCast(inputs.min_file_size_bytes) else 0;
        const max_bytes: u64 = if (inputs.max_file_size_mb > 0)
            @as(u64, @intCast(inputs.max_file_size_mb)) * 1024 * 1024
        else
            std.math.maxInt(u64);

        const below_min_size = file_size < min_bytes;
        const exceeds_size_limit = file_size > max_bytes;

        return .{
            .file_size = file_size,
            .below_min_size = below_min_size,
            .exceeds_size_limit = exceeds_size_limit,
            .size_valid = !below_min_size and !exceeds_size_limit,
        };
    }
};
