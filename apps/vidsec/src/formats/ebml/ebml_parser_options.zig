const std = @import("std");

pub const MAX_NESTING_DEPTH: usize = 32;

/// Parsing options configuring EBML parser traversal and limits.
pub const EbmlParserOptions = struct {
    max_depth: u16 = MAX_NESTING_DEPTH,
    recurse_clusters: bool = false,
};
