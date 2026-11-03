const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("vidsec_formats_common");
const ByteSource = common.ByteSource;
const ElementHeader = @import("element_header.zig").ElementHeader;
const ParsedElement = @import("parsed_element.zig").ParsedElement;
const ElementRole = @import("element_role.zig").ElementRole;
const ParserIssue = @import("parser_issue.zig").ParserIssue;
const ParserIssueCode = @import("parser_issue_code.zig").ParserIssueCode;
const EbmlParserOptions = @import("ebml_parser_options.zig").EbmlParserOptions;
const EbmlParseResult = @import("ebml_parse_result.zig").EbmlParseResult;
const readElementHeader = @import("read_element_header.zig").readElementHeader;
const ebml_constants = @import("ebml_constants.zig");
const vint = @import("vint.zig");

pub const MAX_NESTING_DEPTH: usize = 32;

/// High-performance, iterative, bounded-depth parser for EBML streams.
pub const SafeEbmlParser = struct {
    allocator: Allocator,
    options: EbmlParserOptions,

    pub fn init(allocator: Allocator, options: EbmlParserOptions) SafeEbmlParser {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn parse(self: SafeEbmlParser, source: ByteSource) !EbmlParseResult {
        return self.parseWithDiagnostics(source, &.{}, null);
    }

    /// Robust, iterative EBML parser with support for injected in-line checks and diagnostics.
    pub fn parseWithDiagnostics(
        self: SafeEbmlParser,
        source: ByteSource,
        in_line_checks: []const common.InLineCheck,
        diagnostics_opt: ?*common.DiagnosticList,
    ) !EbmlParseResult {
        var elements = std.ArrayList(ParsedElement).empty;
        errdefer elements.deinit(self.allocator);

        var issues = std.ArrayList(ParserIssue).empty;
        errdefer issues.deinit(self.allocator);

        const StackFrame = struct {
            element_id: u32,
            parsed_idx: u32,
            end_offset: u64,
            is_unknown_size: bool,
        };

        var frame_stack: [MAX_NESTING_DEPTH]StackFrame = undefined;
        var stack_len: usize = 0;

        var curr_offset: u64 = 0;
        var is_first_element = true;
        var has_ebml_header = false;
        var has_segment = false;
        var cluster_count: u32 = 0;
        var total_cluster_bytes: u64 = 0;
        var highest_root_end: u64 = 0;

        var doc_type_buf: [64]u8 = undefined;
        var doc_type_str: []const u8 = "";
        var doc_type_version: u32 = 0;

        while (curr_offset < source.file_size) {
            // 1. Pop frames that have ended at or before curr_offset
            while (stack_len > 0) {
                const top = &frame_stack[stack_len - 1];
                if (!top.is_unknown_size and curr_offset >= top.end_offset) {
                    stack_len -= 1;
                } else {
                    break;
                }
            }

            if (curr_offset >= source.file_size) break;

            // 2. Read Element Header
            const header_opt = try readElementHeader(source, curr_offset);
            if (header_opt == null) {
                const unparsed = source.file_size - curr_offset;
                if (unparsed > 0) {
                    try issues.append(self.allocator, .{
                        .code = .element_header_truncated,
                        .offset = curr_offset,
                        .details = "Truncated or unparseable EBML element header",
                    });
                }
                break;
            }

            const header = header_opt.?;

            // Execute injected in-line checks
            if (diagnostics_opt) |diag| {
                var id_buf: [16]u8 = undefined;
                const id_formatted = std.fmt.bufPrint(&id_buf, "0x{X:0>8}", .{header.id}) catch "0xUNKNOWN";
                const elem_ctx = common.ElementContext{
                    .offset = curr_offset,
                    .declared_size = header.data_size,
                    .header_size = @intCast(header.headerSize()),
                    .depth = @intCast(stack_len),
                    .id_str = id_formatted,
                    .file_size = source.file_size,
                    .source = source,
                };
                for (in_line_checks) |chk| {
                    try chk.execute(elem_ctx, diag, self.allocator);
                }
            }

            // 3. Grammar sanity checks
            const end_offset = if (header.is_unknown_size)
                source.file_size
            else
                curr_offset +| header.totalSize();

            if (!header.is_unknown_size and end_offset > source.file_size) {
                try issues.append(self.allocator, .{
                    .code = .size_extends_beyond_eof,
                    .offset = curr_offset,
                    .element_id = header.id,
                    .details = "Element data size extends beyond end of file",
                });
            }

            // Check if element spills out of parent master element bounds
            if (stack_len > 0) {
                const parent_frame = frame_stack[stack_len - 1];
                if (!parent_frame.is_unknown_size and end_offset > parent_frame.end_offset) {
                    try issues.append(self.allocator, .{
                        .code = .size_extends_beyond_eof,
                        .offset = curr_offset,
                        .element_id = header.id,
                        .details = "Element extends beyond parent master container end offset",
                    });
                }
            }

            // 4. Structural positioning rules
            if (is_first_element) {
                if (header.id != ebml_constants.ID_EBML_HEADER) {
                    try issues.append(self.allocator, .{
                        .code = .ebml_header_not_first,
                        .offset = curr_offset,
                        .element_id = header.id,
                        .details = "EBML file does not start with EBML Header (0x1A45DFA3)",
                    });
                } else {
                    has_ebml_header = true;
                }
            } else if (header.id == ebml_constants.ID_EBML_HEADER) {
                try issues.append(self.allocator, .{
                    .code = .duplicate_ebml_header,
                    .offset = curr_offset,
                    .element_id = header.id,
                    .details = "Duplicate EBML Header element encountered",
                });
            }

            if (header.id == ebml_constants.ID_SEGMENT) {
                has_segment = true;
            } else if (header.id == ebml_constants.ID_CLUSTER) {
                cluster_count += 1;
                total_cluster_bytes += header.totalSize();
            }

            // Extract DocType & DocTypeVersion if inside EBML header
            if (header.id == ebml_constants.ID_DOC_TYPE and doc_type_str.len == 0) {
                doc_type_str = try vint.readString(source, &doc_type_buf, header.payloadOffset(), header.data_size);
            } else if (header.id == ebml_constants.ID_DOC_TYPE_VERSION and doc_type_version == 0) {
                doc_type_version = @truncate(try vint.readUint(source, header.payloadOffset(), header.data_size));
            }

            // 5. Index element in hierarchy
            const parent_idx: ?u32 = if (stack_len > 0) frame_stack[stack_len - 1].parsed_idx else null;
            const current_idx: u32 = @intCast(elements.items.len);

            if (parent_idx) |pidx| {
                if (pidx < elements.items.len) {
                    elements.items[pidx].child_count += 1;
                }
            }

            try elements.append(self.allocator, .{
                .id = header.id,
                .parent_id = parent_idx,
                .depth = @intCast(stack_len),
                .header = header,
                .role = ElementRole.fromId(header.id),
            });

            if (stack_len == 0) {
                highest_root_end = @max(highest_root_end, end_offset);
            }

            is_first_element = false;

            // 6. Navigation: Master container recursion vs. element skipping
            const is_master = ebml_constants.isMasterElement(header.id);
            const is_cluster = (header.id == ebml_constants.ID_CLUSTER);
            const should_recurse = is_master and (!is_cluster or self.options.recurse_clusters);

            if (should_recurse and stack_len < self.options.max_depth) {
                frame_stack[stack_len] = .{
                    .element_id = header.id,
                    .parsed_idx = current_idx,
                    .end_offset = end_offset,
                    .is_unknown_size = header.is_unknown_size,
                };
                stack_len += 1;
                curr_offset = header.payloadOffset();
            } else {
                curr_offset = end_offset;
            }
        }

        if (!has_ebml_header) {
            try issues.append(self.allocator, .{
                .code = .missing_ebml_header,
                .offset = 0,
                .details = "Stream is missing required top-level EBML Header",
            });
        }

        const trailing_slack = if (source.file_size > highest_root_end)
            source.file_size - highest_root_end
        else
            0;

        if (trailing_slack > 0) {
            try issues.append(self.allocator, .{
                .code = .trailing_unparsed_slack,
                .offset = highest_root_end,
                .details = "Trailing unparsed bytes after highest root EBML element",
            });
        }

        const owned_doc_type = if (doc_type_str.len > 0)
            try self.allocator.dupe(u8, doc_type_str)
        else
            "";

        return EbmlParseResult{
            .elements = try elements.toOwnedSlice(self.allocator),
            .issues = try issues.toOwnedSlice(self.allocator),
            .doc_type = owned_doc_type,
            .doc_type_version = doc_type_version,
            .has_ebml_header = has_ebml_header,
            .has_segment = has_segment,
            .cluster_count = cluster_count,
            .total_cluster_bytes = total_cluster_bytes,
            .highest_root_end = highest_root_end,
            .trailing_slack_bytes = trailing_slack,
        };
    }
};
