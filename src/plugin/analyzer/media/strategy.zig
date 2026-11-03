const std = @import("std");
const abi = @import("vidsec_abi");

pub const LowerTracksFn = *const fn (ctx: abi.TaskContext, config_counter: *i64) abi.SdkError!void;

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
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn lowerTracks(abi.TaskContext, *i64) abi.SdkError!void'");
            }
            const FnType = @TypeOf(@field(T, "lowerTracks"));
            const ExpectedFn = fn (abi.TaskContext, *i64) abi.SdkError!void;
            if (FnType != ExpectedFn) {
                @compileError("Type '" ++ @typeName(T) ++ ".lowerTracks' has invalid signature: expected 'fn (abi.TaskContext, *i64) abi.SdkError!void'");
            }
            if (!@hasDecl(T, "strategy")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub const strategy: MediaLoweringStrategy'");
            }
            const StratType = @TypeOf(@field(T, "strategy"));
            if (StratType != MediaLoweringStrategy) {
                @compileError("Type '" ++ @typeName(T) ++ ".strategy' must be of type MediaLoweringStrategy");
            }
        }
    }
};

/// Strict interface contract for lowering format-specific sample extent records into unified IR.
pub const SampleLoweringStrategy = struct {
    lower_samples: *const fn (ctx: abi.TaskContext) abi.SdkError!void,

    /// Statically asserts at compile-time that type `T` strictly implements the `SampleLoweringStrategy` interface contract.
    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "lowerSamples")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn lowerSamples(abi.TaskContext) abi.SdkError!void'");
            }
            const FnType = @TypeOf(@field(T, "lowerSamples"));
            const ExpectedFn = fn (abi.TaskContext) abi.SdkError!void;
            if (FnType != ExpectedFn) {
                @compileError("Type '" ++ @typeName(T) ++ ".lowerSamples' has invalid signature: expected 'fn (abi.TaskContext) abi.SdkError!void'");
            }
            if (!@hasDecl(T, "strategy")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub const strategy: SampleLoweringStrategy'");
            }
        }
    }
};
