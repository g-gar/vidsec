const std = @import("std");

/// Error conditions detected during EBML grammar parsing.
pub const ParserIssueCode = enum {
    vint_invalid_lead_zero,
    vint_exceeds_max_octets,
    id_length_exceeds_4_bytes,
    size_extends_beyond_eof,
    element_header_truncated,
    nesting_depth_exceeded,
    ebml_header_not_first,
    duplicate_ebml_header,
    missing_ebml_header,
    unsupported_doc_type,
    trailing_unparsed_slack,

    pub fn asText(self: ParserIssueCode) []const u8 {
        return switch (self) {
            .vint_invalid_lead_zero => "EBML_VINT_INVALID_LEAD_ZERO",
            .vint_exceeds_max_octets => "EBML_VINT_EXCEEDS_MAX_OCTETS",
            .id_length_exceeds_4_bytes => "EBML_ID_LENGTH_EXCEEDS_4_BYTES",
            .size_extends_beyond_eof => "EBML_SIZE_EXTENDS_BEYOND_EOF",
            .element_header_truncated => "EBML_ELEMENT_HEADER_TRUNCATED",
            .nesting_depth_exceeded => "EBML_NESTING_DEPTH_EXCEEDED",
            .ebml_header_not_first => "EBML_HEADER_NOT_FIRST",
            .duplicate_ebml_header => "EBML_DUPLICATE_HEADER",
            .missing_ebml_header => "EBML_MISSING_HEADER",
            .unsupported_doc_type => "EBML_UNSUPPORTED_DOC_TYPE",
            .trailing_unparsed_slack => "EBML_TRAILING_UNPARSED_SLACK",
        };
    }
};
