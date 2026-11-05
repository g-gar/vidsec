/// Semantic version of a plugin module.
pub const SemVer_ABI = extern struct {
    major: u16,
    minor: u16,
    patch: u16,

    pub fn format(self: SemVer_ABI, writer: anytype) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};
