const std = @import("std");

/// Severity levels for forensics findings.
pub const Severity = enum(u8) {
    info = 0,
    warning = 1,
    critical = 2,

    pub fn asText(self: Severity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .critical => "critical",
        };
    }
};
