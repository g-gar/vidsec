const std = @import("std");
const Allocator = std.mem.Allocator;
const LoaderError = @import("loader_error.zig").LoaderError;

const c_stat = @cImport({
    @cInclude("sys/stat.h");
});

/// Verifies via POSIX `stat()` that the `.so` file at `path` exists, is a regular file,
/// and is NOT group-writable or world-writable (`(st_mode & 0o022) == 0`).
pub fn verifySafeModulePermissions(allocator: Allocator, path: []const u8) LoaderError!void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var st: c_stat.struct_stat = undefined;
    if (c_stat.stat(path_z.ptr, &st) != 0) {
        return error.ModuleFileNotFound;
    }

    const file_type = st.st_mode & c_stat.S_IFMT;
    if (file_type != c_stat.S_IFREG) {
        return error.NotARegularFile;
    }

    // Reject group-writable (0o020) or world-writable (0o002) shared objects
    if ((st.st_mode & 0o022) != 0) {
        return error.InsecureModulePermissions;
    }
}
