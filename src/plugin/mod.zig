const std = @import("std");
const abi = @import("vidsec_abi");

/// Stage 0 Lightweight Video Triaging Plugin (`libtriage.so` / `triage/probe_file`).
pub const triage = @import("triage/mod.zig");

/// Stage 2 Intermediate Representation Plugin (`libir.so` / `ir/lower_container`, `ir/lower_media`).
pub const ir = @import("ir/mod.zig");

/// Stage 3 Deep Forensics & Security Audit Plugin (`libforensics.so` / `forensics/analyze_topology`, `forensics/scan_entropy`, `forensics/check_inconsistencies`).
pub const forensics = @import("forensics/mod.zig");

/// Stage 4 Remediation & Content Disarm Plugin (`libremediation.so` / `remediation/sanitize`, `remediation/carve_quarantine`).
pub const remediation = @import("remediation/mod.zig");


