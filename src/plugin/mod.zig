const std = @import("std");
const abi = @import("vidsec_abi");

/// Consolidated Universal Multimedia Analyzer Plugin (`libanalyzer.so`).
pub const analyzer = @import("analyzer/mod.zig");

// Backward compatibility aliases for existing tests
pub const triage = analyzer;
pub const forensics = analyzer;
pub const ir = analyzer;

/// Stage 4 Remediation & Content Disarm Plugin (`libremediation.so` / `remediation/sanitize`, `remediation/carve_quarantine`).
pub const remediation = @import("remediation/mod.zig");
