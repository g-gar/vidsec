const std = @import("std");
const common = @import("vidsec_formats_common");
const ByteSource = common.ByteSource;
const FourCC = @import("fourcc.zig").FourCC;
const BoxHeader = @import("box_header.zig").BoxHeader;
const ParsedBox = @import("parsed_box.zig").ParsedBox;
const BoxRole = @import("box_role.zig").BoxRole;
const ParserIssue = @import("parser_issue.zig").ParserIssue;
const ParserIssueCode = @import("parser_issue_code.zig").ParserIssueCode;
const ParseResult = @import("parse_result.zig").ParseResult;
const readBoxHeader = @import("read_box_header.zig").readBoxHeader;
const box_constants = @import("box_constants.zig");

pub const MAX_NESTING_DEPTH: usize = 32;

/// Stack frame used to track nesting inside container boxes without recursion.
const ContainerFrame = struct {
    box_id: u32,
    end_offset: u64,
    fourcc: FourCC,
};

/// Robust, iterative box tree parser with full structural validation and in-line hook injection.
pub const SafeBoxParser = struct {
    allocator: std.mem.Allocator,
    max_depth: usize = MAX_NESTING_DEPTH,
    max_boxes: usize = 1024,

    pub fn init(allocator: std.mem.Allocator) SafeBoxParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: SafeBoxParser, source: ByteSource) !ParseResult {
        return self.parseWithDiagnostics(source, &.{}, null);
    }

    /// Robust, iterative box tree parser with support for injected in-line checks and diagnostics.
    pub fn parseWithDiagnostics(
        self: SafeBoxParser,
        source: ByteSource,
        in_line_checks: []const common.InLineCheck,
        diagnostics_opt: ?*common.DiagnosticList,
    ) !ParseResult {
        var boxes: std.ArrayList(ParsedBox) = try .initCapacity(self.allocator, 32);
        errdefer boxes.deinit(self.allocator);

        var issues: std.ArrayList(ParserIssue) = try .initCapacity(self.allocator, 8);
        errdefer issues.deinit(self.allocator);

        var frame_stack: [MAX_NESTING_DEPTH]ContainerFrame = undefined;
        var stack_len: usize = 0;

        var curr_offset: u64 = 0;
        var highest_root_end: u64 = 0;
        var has_ftyp: bool = false;
        var has_moov: bool = false;
        var ftyp_count: u32 = 0;
        var moov_count: u32 = 0;
        var is_first_box: bool = true;

        while (curr_offset < source.file_size and boxes.items.len < self.max_boxes) {
            // Pop any container frames that have ended at or before current offset
            while (stack_len > 0 and curr_offset >= frame_stack[stack_len - 1].end_offset) {
                stack_len -= 1;
            }

            // Check if there are sufficient bytes left for an 8-byte box header
            if (curr_offset + 8 > source.file_size) {
                try issues.append(self.allocator, .{
                    .code = .truncated_header,
                    .offset = curr_offset,
                    .details = "Insufficient bytes remaining for box header",
                });
                break;
            }

            const header_opt = try readBoxHeader(source, curr_offset);
            if (header_opt == null) {
                try issues.append(self.allocator, .{
                    .code = .truncated_header,
                    .offset = curr_offset,
                    .details = "Truncated box header",
                });
                break;
            }

            const header = header_opt.?;

            // Execute injected in-line checks
            if (diagnostics_opt) |diag| {
                const elem_ctx = common.ElementContext{
                    .offset = curr_offset,
                    .declared_size = header.size,
                    .header_size = header.header_size,
                    .depth = @intCast(stack_len),
                    .id_str = &header.fourcc.bytes,
                    .file_size = source.file_size,
                    .source = source,
                    .parent_id_str = if (stack_len > 0) &frame_stack[stack_len - 1].fourcc.bytes else null,
                };
                for (in_line_checks) |chk| {
                    try chk.execute(elem_ctx, diag, self.allocator);
                }
            }

            // 1. Sanity check: Size bounds
            if (!header.is_extended_size and !header.is_eof_size and header.size < 8) {
                try issues.append(self.allocator, .{
                    .code = .box_size_invalid,
                    .offset = curr_offset,
                    .fourcc = header.fourcc,
                    .details = "Box size smaller than header minimum (8 bytes)",
                });
                break; // Unrecoverable parsing error
            }

            if (header.is_extended_size and header.size < 16) {
                try issues.append(self.allocator, .{
                    .code = .large_size_invalid,
                    .offset = curr_offset,
                    .fourcc = header.fourcc,
                    .details = "Large size box smaller than header minimum (16 bytes)",
                });
                break;
            }

            // 2. Sanity check: Offset + size overflow
            const end_offset = curr_offset +| header.size;
            if (end_offset > source.file_size) {
                try issues.append(self.allocator, .{
                    .code = .box_size_overflow,
                    .offset = curr_offset,
                    .fourcc = header.fourcc,
                    .details = "Box size extends beyond end of file",
                });
            }

            // 3. FourCC validation
            if (!header.fourcc.isPrintable()) {
                try issues.append(self.allocator, .{
                    .code = .non_printable_fourcc,
                    .offset = curr_offset,
                    .fourcc = header.fourcc,
                    .details = "FourCC contains non-printable control characters",
                });
            }

            // 4. Grammar checks: ftyp position & frequency
            if (header.fourcc.equals(box_constants.BOX_FTYP)) {
                has_ftyp = true;
                ftyp_count += 1;
                if (!is_first_box) {
                    try issues.append(self.allocator, .{
                        .code = .ftyp_not_first_box,
                        .offset = curr_offset,
                        .fourcc = header.fourcc,
                        .details = "ftyp box found but is not at offset 0",
                    });
                }
                if (ftyp_count > 1) {
                    try issues.append(self.allocator, .{
                        .code = .multiple_ftyp,
                        .offset = curr_offset,
                        .fourcc = header.fourcc,
                        .details = "Multiple ftyp boxes present in stream",
                    });
                }
            } else if (is_first_box) {
                try issues.append(self.allocator, .{
                    .code = .missing_ftyp,
                    .offset = curr_offset,
                    .fourcc = header.fourcc,
                    .details = "First box in stream is not an ftyp box",
                });
            }

            // 5. Grammar checks: moov box rules
            if (header.fourcc.equals(box_constants.BOX_MOOV)) {
                has_moov = true;
                moov_count += 1;
                if (!has_ftyp and ftyp_count == 0) {
                    try issues.append(self.allocator, .{
                        .code = .missing_ftyp,
                        .offset = curr_offset,
                        .fourcc = header.fourcc,
                        .details = "moov box encountered before ftyp box",
                    });
                }
                if (moov_count > 1) {
                    try issues.append(self.allocator, .{
                        .code = .multiple_moov,
                        .offset = curr_offset,
                        .fourcc = header.fourcc,
                        .details = "Multiple moov boxes present in container",
                    });
                }
            }

            // Extract optional FullBox version/flags if box size allows
            var is_full_box = false;
            var fb_version: u8 = 0;
            var fb_flags: u24 = 0;

            if (header.payloadSize() >= 4 and
                (header.fourcc.equals(box_constants.BOX_MVHD) or
                header.fourcc.equals(box_constants.BOX_TKHD) or
                header.fourcc.equals(box_constants.BOX_MDHD) or
                header.fourcc.equals(box_constants.BOX_HDLR) or
                header.fourcc.equals(box_constants.BOX_VMHD) or
                header.fourcc.equals(box_constants.BOX_SMHD) or
                header.fourcc.equals(box_constants.BOX_DREF) or
                header.fourcc.equals(box_constants.BOX_STSD) or
                header.fourcc.equals(box_constants.BOX_STTS) or
                header.fourcc.equals(box_constants.BOX_CTTS) or
                header.fourcc.equals(box_constants.BOX_STSC) or
                header.fourcc.equals(box_constants.BOX_STSZ) or
                header.fourcc.equals(box_constants.BOX_STCO) or
                header.fourcc.equals(box_constants.BOX_CO64) or
                header.fourcc.equals(box_constants.BOX_STSS) or
                header.fourcc.equals(box_constants.BOX_MEHD) or
                header.fourcc.equals(box_constants.BOX_TREX) or
                header.fourcc.equals(box_constants.BOX_MFHD) or
                header.fourcc.equals(box_constants.BOX_TFHD) or
                header.fourcc.equals(box_constants.BOX_TRUN)))
            {
                var fb_buf: [4]u8 = undefined;
                const fb_read = source.readAt(&fb_buf, header.payloadOffset()) catch 0;
                if (fb_read == 4) {
                    is_full_box = true;
                    fb_version = fb_buf[0];
                    fb_flags = (@as(u24, fb_buf[1]) << 16) |
                        (@as(u24, fb_buf[2]) << 8) |
                        @as(u24, fb_buf[3]);
                }
            }

            const current_id: u32 = @intCast(boxes.items.len);
            const parent_id_opt: ?u32 = if (stack_len > 0) frame_stack[stack_len - 1].box_id else null;

            if (parent_id_opt) |pid| {
                boxes.items[pid].child_count += 1;
            }

            try boxes.append(self.allocator, .{
                .id = current_id,
                .parent_id = parent_id_opt,
                .depth = @intCast(stack_len),
                .header = header,
                .is_full_box = is_full_box,
                .version = fb_version,
                .flags = fb_flags,
                .role = BoxRole.fromFourCC(header.fourcc),
            });

            if (stack_len == 0) {
                highest_root_end = @max(highest_root_end, end_offset);
            }

            is_first_box = false;

            // 6. Navigation: Container recursion vs. sibling skipping
            const is_container = box_constants.isContainerBox(header.fourcc);
            if (is_container and header.payloadSize() >= 8 and stack_len < self.max_depth) {
                // Push current container frame and descend into payload
                frame_stack[stack_len] = .{
                    .box_id = current_id,
                    .end_offset = end_offset,
                    .fourcc = header.fourcc,
                };
                stack_len += 1;
                curr_offset = header.payloadOffset();
            } else {
                // If it's a leaf box (or container at max depth / malformed), advance to next box
                if (header.size == 0) {
                    // Size 0 extends to EOF; terminate traversal
                    break;
                }
                curr_offset = end_offset;
            }
        }

        // 7. Post-traversal sanity checks
        if (!has_moov and moov_count == 0) {
            try issues.append(self.allocator, .{
                .code = .missing_moov,
                .offset = 0,
                .details = "No moov box found in container",
            });
        }

        if (highest_root_end > 0 and highest_root_end < source.file_size) {
            const trailing_slack = source.file_size - highest_root_end;
            if (trailing_slack > 4) { // Ignore minor padding tolerance
                try issues.append(self.allocator, .{
                    .code = .orphaned_trailing_data,
                    .offset = highest_root_end,
                    .details = "Trailing overlay data after last root box",
                });
            }
        }

        return .{
            .boxes = try boxes.toOwnedSlice(self.allocator),
            .issues = try issues.toOwnedSlice(self.allocator),
            .highest_root_end = highest_root_end,
            .has_ftyp = has_ftyp,
            .has_moov = has_moov,
            .moov_count = moov_count,
            .ftyp_count = ftyp_count,
        };
    }
};
