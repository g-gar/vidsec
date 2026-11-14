const abi = @import("flowdata_abi");
const magic = @import("vidsec_magic");

pub const TAIL_WINDOW_BYTES: usize = 8192;

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
};

pub const Outputs = struct {
    tail_size_read: u64,
    zip_eocd_offset: ?u64,
    rar_offset: ?u64,
    seven_z_offset: ?u64,
    has_tail_polyglot: bool,
};

/// Scans the trailing bytes of the stream for appended archive polyglots (`ZIP EOCD`, `RAR`, `7z`).
pub const Service = struct {
    pub fn execute(_: *const Service, inputs: Inputs) !Outputs {
        const file_size = inputs.stream.len();
        const tail_len: usize = @intCast(@min(file_size, TAIL_WINDOW_BYTES));
        var tail_buf: [TAIL_WINDOW_BYTES]u8 = undefined;

        var scan = magic.TailArchiveScan{};
        if (tail_len > 0) {
            const tail_offset: u64 = file_size - tail_len;
            try inputs.stream.readAt(tail_offset, tail_buf[0..tail_len]);
            scan = magic.scanTailArchives(tail_buf[0..tail_len], tail_offset);
        }

        return .{
            .tail_size_read = tail_len,
            .zip_eocd_offset = scan.zip_eocd_offset,
            .rar_offset = scan.rar_offset,
            .seven_z_offset = scan.seven_z_offset,
            .has_tail_polyglot = scan.zip_eocd_offset != null or scan.rar_offset != null or scan.seven_z_offset != null,
        };
    }
};
