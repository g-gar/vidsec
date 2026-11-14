const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("media_ir").common;
const ByteSource = common.ByteSource;
const FourCC = @import("fourcc.zig").FourCC;
const ChunkHeader = @import("chunk_header.zig").ChunkHeader;
const ParsedChunk = @import("parsed_chunk.zig").ParsedChunk;
const ChunkRole = @import("chunk_role.zig").ChunkRole;
const ParserIssue = @import("parser_issue.zig").ParserIssue;
const ParserIssueCode = @import("parser_issue_code.zig").ParserIssueCode;
const RiffParserOptions = @import("riff_parser_options.zig").RiffParserOptions;
const RiffParseResult = @import("riff_parse_result.zig").RiffParseResult;
const riff_constants = @import("riff_constants.zig");

pub const MAX_NESTING_DEPTH: usize = 32;

/// High-performance, iterative, bounded-depth parser for RIFF containers.
pub const SafeRiffParser = struct {
    allocator: Allocator,
    options: RiffParserOptions,

    pub fn init(allocator: Allocator, options: RiffParserOptions) SafeRiffParser {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn parse(self: SafeRiffParser, source: ByteSource) !RiffParseResult {
        return self.parseWithDiagnostics(source, &.{}, null);
    }

    /// Robust, iterative RIFF parser with support for injected in-line checks and diagnostics.
    pub fn parseWithDiagnostics(
        self: SafeRiffParser,
        source: ByteSource,
        in_line_checks: []const common.InLineCheck,
        diagnostics_opt: ?*common.DiagnosticList,
    ) !RiffParseResult {
        var chunks = std.ArrayList(ParsedChunk).empty;
        errdefer chunks.deinit(self.allocator);

        var issues = std.ArrayList(ParserIssue).empty;
        errdefer issues.deinit(self.allocator);

        if (source.file_size < 12) {
            try issues.append(self.allocator, .{
                .code = .truncated_chunk_header,
                .offset = 0,
                .details = "File smaller than 12-byte minimum RIFF header",
            });
            return RiffParseResult{
                .chunks = try chunks.toOwnedSlice(self.allocator),
                .issues = try issues.toOwnedSlice(self.allocator),
                .form_type = FourCC.init("    "),
                .root_size = 0,
                .movi_bytes = 0,
                .junk_bytes = 0,
                .highest_root_end = 0,
                .trailing_slack_bytes = 0,
            };
        }

        // 1. Read Root RIFF Header (offset 0..12)
        var root_hdr_buf: [12]u8 = undefined;
        _ = try source.readAt(&root_hdr_buf, 0);

        const root_fourcc = FourCC{ .bytes = root_hdr_buf[0..4].* };
        const is_rifx = root_fourcc.equals(riff_constants.FOURCC_RIFX);
        const endian: std.builtin.Endian = if (is_rifx) .big else .little;

        const is_valid_root = root_fourcc.equals(riff_constants.FOURCC_RIFF) or
            root_fourcc.equals(riff_constants.FOURCC_RIFX) or
            root_fourcc.equals(riff_constants.FOURCC_RF64);

        if (!is_valid_root) {
            try issues.append(self.allocator, .{
                .code = .riff_magic_invalid,
                .offset = 0,
                .fourcc = root_fourcc,
                .details = "Initial 4 bytes do not match RIFF, RIFX, or RF64 signature",
            });
        }

        const root_size_raw = std.mem.readInt(u32, root_hdr_buf[4..8], endian);
        const form_type = FourCC{ .bytes = root_hdr_buf[8..12].* };

        if (root_size_raw < 4) {
            try issues.append(self.allocator, .{
                .code = .root_size_too_small,
                .offset = 0,
                .fourcc = root_fourcc,
                .details = "Root RIFF declared size < 4 bytes (smaller than form type)",
            });
        }

        const root_header = ChunkHeader{
            .fourcc = root_fourcc,
            .size = root_size_raw,
            .offset = 0,
            .form_or_list_type = form_type,
            .is_padded = (root_size_raw & 1 == 1),
        };

        // In-line checks for root header
        if (diagnostics_opt) |diag| {
            const elem_ctx = common.ElementContext{
                .offset = 0,
                .declared_size = @as(u64, root_size_raw) + 8,
                .header_size = 12,
                .depth = 0,
                .id_str = &root_fourcc.bytes,
                .file_size = source.file_size,
                .source = source,
            };
            for (in_line_checks) |chk| {
                try chk.execute(elem_ctx, diag, self.allocator);
            }
        }

        try chunks.append(self.allocator, .{
            .id = 0,
            .parent_id = null,
            .depth = 0,
            .header = root_header,
            .role = .header,
        });

        const root_end = 8 +| @as(u64, root_size_raw);
        if (root_end > source.file_size) {
            try issues.append(self.allocator, .{
                .code = .chunk_size_overflow,
                .offset = 0,
                .fourcc = root_fourcc,
                .details = "Root RIFF chunk size extends beyond end of file",
            });
        }

        const StackFrame = struct {
            parsed_idx: u32,
            end_offset: u64,
            list_type: ?FourCC,
        };

        var frame_stack: [MAX_NESTING_DEPTH]StackFrame = undefined;
        var stack_len: usize = 0;

        frame_stack[0] = .{
            .parsed_idx = 0,
            .end_offset = @min(root_end, source.file_size),
            .list_type = form_type,
        };
        stack_len = 1;

        var curr_offset: u64 = 12; // first chunk inside root starts after form_type
        var movi_bytes: u64 = 0;
        var junk_bytes: u64 = 0;
        const highest_root_end: u64 = root_end;

        while (curr_offset < source.file_size) {
            // Pop frames whose boundary has been reached
            while (stack_len > 0 and curr_offset >= frame_stack[stack_len - 1].end_offset) {
                stack_len -= 1;
            }

            if (stack_len == 0 or curr_offset >= source.file_size) break;

            if (curr_offset + 8 > source.file_size) {
                try issues.append(self.allocator, .{
                    .code = .truncated_chunk_header,
                    .offset = curr_offset,
                    .details = "Fewer than 8 bytes remaining for chunk header",
                });
                break;
            }

            var chunk_buf: [8]u8 = undefined;
            if ((try source.readAt(&chunk_buf, curr_offset)) < 8) break;

            const c_fourcc = FourCC{ .bytes = chunk_buf[0..4].* };
            const c_size = std.mem.readInt(u32, chunk_buf[4..8], endian);
            const is_padded = (c_size & 1 == 1);
            const c_pad_byte: u64 = if (is_padded) 1 else 0;
            const c_total_bytes = 8 + @as(u64, c_size) + c_pad_byte;

            const end_offset = curr_offset +| c_total_bytes;

            if (diagnostics_opt) |diag| {
                const elem_ctx = common.ElementContext{
                    .offset = curr_offset,
                    .declared_size = @as(u64, c_size) + 8,
                    .header_size = 8,
                    .depth = @intCast(stack_len),
                    .id_str = &c_fourcc.bytes,
                    .file_size = source.file_size,
                    .source = source,
                };
                for (in_line_checks) |chk| {
                    try chk.execute(elem_ctx, diag, self.allocator);
                }
            }

            if (end_offset > source.file_size) {
                try issues.append(self.allocator, .{
                    .code = .chunk_size_overflow,
                    .offset = curr_offset,
                    .fourcc = c_fourcc,
                    .details = "Chunk size extends beyond end of file",
                });
            }

            const parent_frame = frame_stack[stack_len - 1];
            if (end_offset > parent_frame.end_offset) {
                try issues.append(self.allocator, .{
                    .code = .chunk_extends_past_parent,
                    .offset = curr_offset,
                    .fourcc = c_fourcc,
                    .details = "Chunk extends beyond enclosing LIST container boundary",
                });
            }

            const is_list = c_fourcc.equals(riff_constants.FOURCC_LIST);
            var list_type: ?FourCC = null;

            if (is_list and c_size >= 4) {
                var lt_buf: [4]u8 = undefined;
                if ((try source.readAt(&lt_buf, curr_offset + 8)) == 4) {
                    list_type = FourCC{ .bytes = lt_buf };
                }
            }

            const c_role = ChunkRole.fromFourCC(c_fourcc, list_type);

            if (c_fourcc.equals(riff_constants.CHUNK_JUNK) or c_fourcc.equals(riff_constants.CHUNK_PAD)) {
                junk_bytes += c_total_bytes;
            } else if (list_type != null and list_type.?.equals(riff_constants.LIST_MOVI)) {
                movi_bytes += c_total_bytes;
            }

            const parent_idx: ?u32 = parent_frame.parsed_idx;
            const current_idx: u32 = @intCast(chunks.items.len);

            if (parent_idx) |pidx| {
                if (pidx < chunks.items.len) {
                    chunks.items[pidx].child_count += 1;
                }
            }

            const chunk_header = ChunkHeader{
                .fourcc = c_fourcc,
                .size = c_size,
                .offset = curr_offset,
                .form_or_list_type = list_type,
                .is_padded = is_padded,
            };

            try chunks.append(self.allocator, .{
                .id = current_idx,
                .parent_id = parent_idx,
                .depth = @intCast(stack_len),
                .header = chunk_header,
                .role = c_role,
            });

            // Container recursion vs. sibling advance
            const is_movi = (list_type != null and list_type.?.equals(riff_constants.LIST_MOVI));
            const should_recurse = is_list and (!is_movi or self.options.recurse_movi);

            if (should_recurse and stack_len < self.options.max_depth) {
                frame_stack[stack_len] = .{
                    .parsed_idx = current_idx,
                    .end_offset = end_offset,
                    .list_type = list_type,
                };
                stack_len += 1;
                curr_offset += 12; // advance past 8-byte chunk header + 4-byte list_type
            } else {
                curr_offset = end_offset;
            }
        }

        const trailing_slack = if (source.file_size > highest_root_end)
            source.file_size - highest_root_end
        else
            0;

        if (trailing_slack > 64) {
            try issues.append(self.allocator, .{
                .code = .trailing_unparsed_slack,
                .offset = highest_root_end,
                .details = "Trailing unparsed bytes after root RIFF chunk",
            });
        }

        return RiffParseResult{
            .chunks = try chunks.toOwnedSlice(self.allocator),
            .issues = try issues.toOwnedSlice(self.allocator),
            .form_type = form_type,
            .root_size = root_size_raw,
            .movi_bytes = movi_bytes,
            .junk_bytes = junk_bytes,
            .highest_root_end = highest_root_end,
            .trailing_slack_bytes = trailing_slack,
        };
    }
};
