const isobmff = @import("vidsec_isobmff");
const FourCC = isobmff.FourCC;
const AvcCConfig = @import("avcc_config.zig").AvcCConfig;
const EsdsConfig = @import("esds_config.zig").EsdsConfig;
const mp4_constants = @import("mp4_constants.zig");

/// Expanded track representation combining `tkhd`, `mdhd`, `hdlr`, and `stbl` sample tables.
pub const TrackInfo = struct {
    track_id: u32,
    handler_type: FourCC,
    codec_fourcc: FourCC,
    width: u32 = 0,          // From `tkhd` fixed-point 16.16 or visual sample entry
    height: u32 = 0,         // From `tkhd` fixed-point 16.16 or visual sample entry
    duration: u64 = 0,       // Duration in timescale units
    timescale: u32 = 0,      // Timescale from `mdhd`
    sample_count: u32 = 0,   // Total samples declared in `stsz`
    chunk_count: u32 = 0,    // Total chunks declared in `stco` / `co64`
    total_sample_bytes: u64 = 0, // Sum of all sample sizes
    avcc: ?AvcCConfig = null,
    esds: ?EsdsConfig = null,

    pub fn isVideo(self: TrackInfo) bool {
        return self.handler_type.equals(mp4_constants.HANDLER_VIDE);
    }

    pub fn isAudio(self: TrackInfo) bool {
        return self.handler_type.equals(mp4_constants.HANDLER_SOUN);
    }
};
