const std = @import("std");
const abi = @import("vidsec_abi");

/// Multimedia Analysis Plugin (`src/plugin/analysis/`, compiles to `libanalyzer.so`).
pub const analysis = @import("analysis/mod.zig");

/// Stage 4 Remediation & Content Disarm Plugin (`libremediation.so` / `remediation/sanitize`, `remediation/carve_quarantine`).
pub const remediation = @import("remediation/mod.zig");

// First-class domain libraries promoted to `src/plugin/` level
pub const formats = @import("vidsec_formats_common");
pub const isobmff = @import("vidsec_isobmff");
pub const mp4 = @import("vidsec_mp4");
pub const ebml = @import("vidsec_ebml");
pub const mkv = @import("vidsec_mkv");
pub const riff = @import("vidsec_riff");
pub const ir = @import("vidsec_ir");
pub const forensics = @import("vidsec_forensics");
pub const magic = @import("vidsec_magic");
pub const math = @import("vidsec_math");

// Backward compatibility aliases
pub const analyzer = analysis;
pub const triage = analysis;

/// Compatibility namespace for existing tests referencing `vidsec.plugin.lib.*`
pub const lib = struct {
    pub const formats = @import("vidsec_formats_common");
    pub const isobmff = @import("vidsec_isobmff");
    pub const mp4 = @import("vidsec_mp4");
    pub const ebml = @import("vidsec_ebml");
    pub const mkv = @import("vidsec_mkv");
    pub const riff = @import("vidsec_riff");
    pub const ir = @import("vidsec_ir");
    pub const forensics = @import("vidsec_forensics");
    pub const magic = @import("vidsec_magic");
    pub const math = @import("vidsec_math");
};
