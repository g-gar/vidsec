/// Error conditions detected during RIFF structural inspection.
pub const ParserIssueCode = enum {
    riff_magic_invalid,
    root_size_too_small,
    chunk_size_overflow,
    chunk_extends_past_parent,
    truncated_chunk_header,
    nesting_depth_exceeded,
    missing_odd_byte_padding,
    trailing_unparsed_slack,

    pub fn asText(self: ParserIssueCode) []const u8 {
        return switch (self) {
            .riff_magic_invalid => "RIFF_MAGIC_INVALID",
            .root_size_too_small => "RIFF_ROOT_SIZE_TOO_SMALL",
            .chunk_size_overflow => "RIFF_CHUNK_SIZE_OVERFLOW",
            .chunk_extends_past_parent => "RIFF_CHUNK_EXTENDS_PAST_PARENT",
            .truncated_chunk_header => "RIFF_TRUNCATED_CHUNK_HEADER",
            .nesting_depth_exceeded => "RIFF_NESTING_DEPTH_EXCEEDED",
            .missing_odd_byte_padding => "RIFF_MISSING_ODD_BYTE_PADDING",
            .trailing_unparsed_slack => "RIFF_TRAILING_UNPARSED_SLACK",
        };
    }
};
