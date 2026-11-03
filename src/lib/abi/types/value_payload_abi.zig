const Slice_ABI = @import("slice_abi.zig").Slice_ABI;

/// Untagged C union holding the payload of a `Value_ABI`.
pub const ValuePayload_ABI = extern union {
    int64: i64,
    float64: f64,
    boolean: bool,
    slice: Slice_ABI,
};
