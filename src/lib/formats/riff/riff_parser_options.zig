pub const MAX_NESTING_DEPTH: usize = 32;

/// Parsing options configuring RIFF traversal limits.
pub const RiffParserOptions = struct {
    max_depth: u16 = MAX_NESTING_DEPTH,
    recurse_movi: bool = false,
};
