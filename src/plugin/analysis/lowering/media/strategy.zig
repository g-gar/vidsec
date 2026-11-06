const std = @import("std");
const ir = @import("vidsec_ir");

pub const TrackInput = struct {
    track_id: i64,
    codec_tag: []const u8 = "unknown",
    width: i64 = 0,
    height: i64 = 0,
    bitstream_width: ?i64 = null,
    bitstream_height: ?i64 = null,
};

pub const SampleInput = struct {
    track_id: i64 = 1,
    sample_index: i64 = 1,
    source_tag: []const u8 = "mdat",
    target_offset: u64 = 0,
    byte_size: u64 = 0,
};

pub const LowerTracksFn = *const fn (
    allocator: std.mem.Allocator,
    tracks: []const TrackInput,
    config_counter: *i64,
) anyerror![]ir.IrCodecConfigRow;

/// Strict interface contract for lowering format-specific media and track metadata into unified IR.
pub const MediaLoweringStrategy = struct {
    name: []const u8,
    lower_tracks: LowerTracksFn,

    /// Statically asserts at compile-time that type `T` strictly implements the `MediaLoweringStrategy` interface contract.
    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "name")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub const name: []const u8'");
            }
            if (!@hasDecl(T, "lowerTracks")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn lowerTracks(std.mem.Allocator, []const TrackInput, *i64) ![]ir.IrCodecConfigRow'");
            }
            if (!@hasDecl(T, "strategy")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub const strategy: MediaLoweringStrategy'");
            }
        }
    }
};

pub const LowerSamplesFn = *const fn (
    allocator: std.mem.Allocator,
    samples: []const SampleInput,
    extent_counter: *i64,
) anyerror![]ir.IrSampleExtentRow;

/// Strict interface contract for lowering format-specific sample extent records into unified IR.
pub const SampleLoweringStrategy = struct {
    lower_samples: LowerSamplesFn,

    /// Statically asserts at compile-time that type `T` strictly implements the `SampleLoweringStrategy` interface contract.
    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "lowerSamples")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn lowerSamples(std.mem.Allocator, []const SampleInput, *i64) ![]ir.IrSampleExtentRow'");
            }
            if (!@hasDecl(T, "strategy")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub const strategy: SampleLoweringStrategy'");
            }
        }
    }
};
