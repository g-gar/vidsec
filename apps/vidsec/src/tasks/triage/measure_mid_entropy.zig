const abi = @import("flowdata_abi");
const math = @import("vidsec_math");

pub const MID_WINDOW_BYTES: usize = 4096;

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
    min_mid_entropy: f64 = 5.5,
};

pub const Outputs = struct {
    mid_entropy: f64,
    window_bytes_read: u64,
    low_mid_entropy: bool,
};

/// Measures Shannon entropy over a bounded window at the midpoint of the stream.
pub const Service = struct {
    pub fn execute(_: *const Service, inputs: Inputs) !Outputs {
        const file_size = inputs.stream.len();
        const mid_len: usize = @intCast(@min(file_size, MID_WINDOW_BYTES));
        var mid_buf: [MID_WINDOW_BYTES]u8 = undefined;

        var mid_entropy: f64 = 0.0;
        if (mid_len > 0) {
            const mid_offset: u64 = if (file_size <= MID_WINDOW_BYTES) 0 else (file_size - mid_len) / 2;
            try inputs.stream.readAt(mid_offset, mid_buf[0..mid_len]);
            mid_entropy = math.shannonEntropy(mid_buf[0..mid_len]);
        }

        return .{
            .mid_entropy = mid_entropy,
            .window_bytes_read = mid_len,
            .low_mid_entropy = file_size > 0 and mid_entropy < inputs.min_mid_entropy,
        };
    }
};
