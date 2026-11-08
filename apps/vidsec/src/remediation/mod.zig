const std = @import("std");
const abi = @import("flowdata_abi");

pub const carve = @import("carve.zig");
pub const sanitize = @import("sanitize.zig");

pub const runCarveQuarantine = carve.runCarveQuarantine;
pub const runSanitize = sanitize.runSanitize;

pub const tasks = [_]abi.TaskDescriptor_ABI{
    abi.defineTask(.{
        .name = "carve_quarantine",
        .description = "Stage 4 Remediation: Carves detected malicious payloads, trailing overlays, and suspicious attachments to the quarantine store",
        .output_fields = &.{},
        .required_params = &.{},
        .run = &runCarveQuarantine,
    }),
    abi.defineTask(.{
        .name = "sanitize",
        .description = "Stage 4 Remediation: Sanitizes media container by truncating trailing overlays and zero-filling unreferenced slack/gaps",
        .output_fields = &.{
            "finding_id",
            "is_remediated",
            "remediation_action",
        },
        .required_params = &.{},
        .run = &runSanitize,
    }),
};

pub const manifest: abi.ModuleManifest_ABI = abi.defineManifest(
    "remediation",
    .{ .major = 2, .minor = 0, .patch = 0 },
    &tasks,
);

// Exports the `flowdata_module_manifest` C-ABI symbol when compiled as a standalone `.so` plugin (`libremediation.so`)
comptime {
    if (@import("root") == @This()) {
        @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
    }
}
