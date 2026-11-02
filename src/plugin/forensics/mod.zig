const std = @import("std");
const abi = @import("vidsec_abi");

pub const topology = @import("topology.zig");
pub const entropy = @import("entropy.zig");
pub const inconsistencies = @import("inconsistencies.zig");

pub const runAnalyzeTopology = topology.runAnalyzeTopology;
pub const runScanEntropy = entropy.runScanEntropy;
pub const runCheckInconsistencies = inconsistencies.runCheckInconsistencies;

pub const tasks = [_]abi.TaskDescriptor_ABI{
    abi.defineTask(.{
        .name = "analyze_topology",
        .description = "Stage 3 Forensics: Evaluates interval topology, calculates unreferenced gaps, detects trailing overlays and overlapping regions",
        .output_fields = &.{},
        .required_params = &.{},
        .run = &runAnalyzeTopology,
    }),
    abi.defineTask(.{
        .name = "scan_entropy",
        .description = "Stage 3 Forensics: Computes Shannon entropy over unreferenced slack and gaps to detect hidden encrypted or compressed payloads",
        .output_fields = &.{},
        .required_params = &.{},
        .run = &runScanEntropy,
    }),
    abi.defineTask(.{
        .name = "check_inconsistencies",
        .description = "Stage 3 Forensics: Evaluates container vs bitstream dimension discrepancies and checks sample extent boundaries",
        .output_fields = &.{},
        .required_params = &.{},
        .run = &runCheckInconsistencies,
    }),
};

pub const manifest: abi.ModuleManifest_ABI = abi.defineManifest(
    "forensics",
    .{ .major = 2, .minor = 0, .patch = 0 },
    &tasks,
);

// Exports the `vidsec_module_manifest` C-ABI symbol when compiled as a standalone `.so` plugin (`libforensics.so`)
comptime {
    if (@import("root") == @This()) {
        @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
    }
}
