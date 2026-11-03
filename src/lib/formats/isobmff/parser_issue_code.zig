const std = @import("std");

/// Structural syntax anomalies and integrity issues detected during ISOBMFF parsing.
pub const ParserIssueCode = enum(u8) {
    box_size_invalid = 0,
    box_size_overflow = 1,
    large_size_invalid = 2,
    eof_box_not_at_end = 3,
    non_printable_fourcc = 4,
    unknown_fourcc = 5,
    truncated_header = 6,
    container_cycle_or_overlap = 7,
    excessive_nesting_depth = 8,
    missing_ftyp = 9,
    ftyp_not_first_box = 10,
    multiple_ftyp = 11,
    missing_moov = 12,
    multiple_moov = 13,
    orphaned_trailing_data = 14,
    unindexed_slack_in_mdat = 15,

    pub fn asText(self: ParserIssueCode) []const u8 {
        return switch (self) {
            .box_size_invalid => "ISOBMFF_BOX_SIZE_INVALID",
            .box_size_overflow => "ISOBMFF_BOX_SIZE_OVERFLOW",
            .large_size_invalid => "ISOBMFF_LARGE_SIZE_INVALID",
            .eof_box_not_at_end => "ISOBMFF_EOF_BOX_NOT_AT_END",
            .non_printable_fourcc => "ISOBMFF_NON_PRINTABLE_FOURCC",
            .unknown_fourcc => "ISOBMFF_UNKNOWN_FOURCC",
            .truncated_header => "ISOBMFF_TRUNCATED_HEADER",
            .container_cycle_or_overlap => "ISOBMFF_CONTAINER_CYCLE_OR_OVERLAP",
            .excessive_nesting_depth => "ISOBMFF_EXCESSIVE_NESTING_DEPTH",
            .missing_ftyp => "ISOBMFF_MISSING_FTYP",
            .ftyp_not_first_box => "ISOBMFF_FTYP_NOT_FIRST_BOX",
            .multiple_ftyp => "ISOBMFF_MULTIPLE_FTYP",
            .missing_moov => "ISOBMFF_MISSING_MOOV",
            .multiple_moov => "ISOBMFF_MULTIPLE_MOOV",
            .orphaned_trailing_data => "ISOBMFF_ORPHANED_TRAILING_DATA",
            .unindexed_slack_in_mdat => "ISOBMFF_UNINDEXED_SLACK_IN_MDAT",
        };
    }
};
