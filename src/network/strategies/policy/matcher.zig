const std = @import("std");

/// Case-insensitive wildcard glob matcher (`*` and `?`).
pub fn matchGlob(pattern: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    var p_idx: usize = 0;
    var c_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (c_idx < candidate.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or std.ascii.toLower(pattern[p_idx]) == std.ascii.toLower(candidate[c_idx]))) {
            p_idx += 1;
            c_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = c_idx;
            p_idx += 1;
        } else if (star_idx) |s_idx| {
            p_idx = s_idx + 1;
            match_idx += 1;
            c_idx = match_idx;
        } else {
            return false;
        }
    }
    while (p_idx < pattern.len and pattern[p_idx] == '*') : (p_idx += 1) {}
    return p_idx == pattern.len;
}

/// Matches a URI resource path against either an exact prefix (`/manga`) or glob (`/manga/*`).
pub fn matchResource(pattern: []const u8, resource_path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') != null) {
        const clean_path = if (std.mem.indexOfScalar(u8, pattern, '?') == null)
            (if (std.mem.indexOfScalar(u8, resource_path, '?')) |q| resource_path[0..q] else resource_path)
        else
            resource_path;

        if (std.mem.endsWith(u8, pattern, "/*")) {
            const base = pattern[0 .. pattern.len - 2];
            if (std.mem.eql(u8, clean_path, base)) return true;
        }
        return matchGlob(pattern, clean_path);
    }
    return std.mem.startsWith(u8, resource_path, pattern);
}
