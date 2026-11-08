const BoundedStreamReader = @import("bounded_stream_reader.zig").BoundedStreamReader;

/// Result of creating a child `BoundedStreamReader` where the child's declared end offset
/// may exceed the parent's boundary or overflow 64-bit arithmetic (`R03` anomaly detection).
pub const ClampedSubRegion = struct {
    reader: BoundedStreamReader,
    is_truncated_or_overflow: bool,
};
