const abi = @import("flowdata_abi");
const tika = @import("tika");
const magic = @import("vidsec_magic");

pub const Inputs = struct {
    stream: abi.BoundedStreamReader,
};

pub const Outputs = struct {
    detected_family: []const u8,
    identified_format: []const u8,
    canonical_extension: []const u8,
    mime_type: []const u8,
    true_magic_kind: i64,
    is_video: bool,
    is_hostile: bool,
};

/// Reads the leading header window (`RECOMMENDED_HEADER_BYTES`) and identifies real format/MIME via `tika`.
pub const Service = struct {
    pub fn execute(_: *const Service, inputs: Inputs) !Outputs {
        const file_size = inputs.stream.len();
        var head_buf: [tika.RECOMMENDED_HEADER_BYTES]u8 = undefined;
        const head_len: usize = @intCast(@min(file_size, tika.RECOMMENDED_HEADER_BYTES));
        if (head_len > 0) {
            try inputs.stream.readAt(0, head_buf[0..head_len]);
        }

        const info = tika.detect(head_buf[0..head_len]);
        return .{
            .detected_family = info.family.asText(),
            .identified_format = info.id.asText(),
            .canonical_extension = info.extension,
            .mime_type = info.mime_type,
            .true_magic_kind = magic.kindCode(info),
            .is_video = info.isVideo(),
            .is_hostile = magic.isHostileInMedia(info),
        };
    }
};
