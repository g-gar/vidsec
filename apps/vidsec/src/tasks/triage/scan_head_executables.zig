const abi = @import("flowdata_abi");
const tika = @import("tika");
const magic = @import("vidsec_magic");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
    max_scan_bytes: i64 = tika.RECOMMENDED_HEADER_BYTES,
};

pub const Outputs = struct {
    primary_at_zero: bool,
    secondary_offset: ?u64,
    has_embedded_executable: bool,
};

/// Scans the leading header window for primary or embedded executable signatures (`MZ` / `\x7FELF`).
pub const Service = struct {
    pub fn execute(_: *const Service, inputs: Inputs) !Outputs {
        const file_size = inputs.stream.len();
        const max_bytes: usize = if (inputs.max_scan_bytes > 0)
            @intCast(@min(@as(u64, @intCast(inputs.max_scan_bytes)), tika.RECOMMENDED_HEADER_BYTES))
        else
            tika.RECOMMENDED_HEADER_BYTES;

        var head_buf: [tika.RECOMMENDED_HEADER_BYTES]u8 = undefined;
        const head_len: usize = @intCast(@min(file_size, max_bytes));
        if (head_len > 0) {
            try inputs.stream.readAt(0, head_buf[0..head_len]);
        }

        const scan = magic.scanHeadExecutables(head_buf[0..head_len], head_len);
        return .{
            .primary_at_zero = scan.primary_at_zero,
            .secondary_offset = scan.secondary_offset,
            .has_embedded_executable = scan.primary_at_zero or scan.secondary_offset != null,
        };
    }
};
