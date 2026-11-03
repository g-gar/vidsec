const std = @import("std");
const Allocator = std.mem.Allocator;
const ParsedElement = @import("parsed_element.zig").ParsedElement;
const ParserIssue = @import("parser_issue.zig").ParserIssue;

/// Result of parsing an EBML container stream.
pub const EbmlParseResult = struct {
    elements: []const ParsedElement,
    issues: []const ParserIssue,
    doc_type: []const u8,
    doc_type_version: u32,
    has_ebml_header: bool,
    has_segment: bool,
    cluster_count: u32,
    total_cluster_bytes: u64,
    highest_root_end: u64,
    trailing_slack_bytes: u64,

    pub fn deinit(self: EbmlParseResult, allocator: Allocator) void {
        allocator.free(self.elements);
        allocator.free(self.issues);
        if (self.doc_type.len > 0) {
            allocator.free(self.doc_type);
        }
    }
};
