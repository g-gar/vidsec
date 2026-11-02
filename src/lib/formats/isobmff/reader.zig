const std = @import("std");
const types = @import("types.zig");

pub const FourCC = types.FourCC;
pub const BoxHeader = types.BoxHeader;
pub const FullBoxHeader = types.FullBoxHeader;
pub const ParsedBox = types.ParsedBox;
pub const BoxRole = types.BoxRole;
pub const ParserIssue = types.ParserIssue;
pub const ParserIssueCode = types.ParserIssueCode;

pub const MAX_NESTING_DEPTH: usize = 32;

/// Generic zero-copy byte source interface (works over memory slices or positional stream readers).
pub const ByteSource = struct {
    ctx: *const anyopaque,
    read_at_fn: *const fn (ctx: *const anyopaque, buf: []u8, offset: u64) anyerror!usize,
    file_size: u64,

    pub fn readAt(self: ByteSource, buf: []u8, offset: u64) !usize {
        if (offset >= self.file_size) return 0;
        const available = self.file_size - offset;
        const to_read = @min(buf.len, available);
        if (to_read == 0) return 0;
        return self.read_at_fn(self.ctx, buf[0..to_read], offset);
    }

    /// Creates a ByteSource wrapping a contiguous slice of memory.
    pub fn fromSlice(slice: []const u8) ByteSource {
        const Wrapper = struct {
            fn readSlice(ctx_ptr: *const anyopaque, buf: []u8, offset: u64) anyerror!usize {
                const ptr: [*]const u8 = @ptrCast(ctx_ptr);
                @memcpy(buf, ptr[offset .. offset + buf.len]);
                return buf.len;
            }
        };

        return .{
            .ctx = @ptrCast(slice.ptr),
            .read_at_fn = Wrapper.readSlice,
            .file_size = slice.len,
        };
    }
};

/// Stack frame used to track nesting inside container boxes without recursion.
const ContainerFrame = struct {
    box_id: u32,
    end_offset: u64,
    fourcc: FourCC,
};

/// Result of parsing an ISOBMFF container stream.
pub const ParseResult = struct {
    boxes: []const ParsedBox,
    issues: []const ParserIssue,
    highest_root_end: u64 = 0,
    has_ftyp: bool = false,
    has_moov: bool = false,
    moov_count: u32 = 0,
    ftyp_count: u32 = 0,

    pub fn deinit(self: ParseResult, allocator: std.mem.Allocator) void {
        allocator.free(self.boxes);
        allocator.free(self.issues);
    }
};

/// Checks if a FourCC corresponds to a standard FullBox (having version and flags).
pub fn isStandardFullBox(fourcc: FourCC) bool {
    return fourcc.equals(types.BOX_MVHD) or
        fourcc.equals(types.BOX_TKHD) or
        fourcc.equals(types.BOX_MDHD) or
        fourcc.equals(types.BOX_HDLR) or
        fourcc.equals(types.BOX_VMHD) or
        fourcc.equals(types.BOX_SMHD) or
        fourcc.equals(types.BOX_HMHD) or
        fourcc.equals(types.BOX_NMHD) or
        fourcc.equals(types.BOX_DREF) or
        fourcc.equals(types.BOX_STSD) or
        fourcc.equals(types.BOX_STTS) or
        fourcc.equals(types.BOX_CTTS) or
        fourcc.equals(types.BOX_CSLG) or
        fourcc.equals(types.BOX_STSC) or
        fourcc.equals(types.BOX_STSZ) or
        fourcc.equals(types.BOX_STZ2) or
        fourcc.equals(types.BOX_STCO) or
        fourcc.equals(types.BOX_CO64) or
        fourcc.equals(types.BOX_STSS) or
        fourcc.equals(types.BOX_STSH) or
        fourcc.equals(types.BOX_PADB) or
        fourcc.equals(types.BOX_SDTP) or
        fourcc.equals(types.BOX_SBGP) or
        fourcc.equals(types.BOX_SGPD) or
        fourcc.equals(types.BOX_SUBS) or
        fourcc.equals(types.BOX_SAIZ) or
        fourcc.equals(types.BOX_SAIO) or
        fourcc.equals(types.BOX_MFHD) or
        fourcc.equals(types.BOX_TFHD) or
        fourcc.equals(types.BOX_TRUN) or
        fourcc.equals(types.BOX_TFRA) or
        fourcc.equals(types.BOX_MFRO) or
        fourcc.equals(types.BOX_TREX) or
        fourcc.equals(types.BOX_MEHD) or
        fourcc.equals(types.BOX_SIDX) or
        fourcc.equals(types.BOX_SSIX) or
        fourcc.equals(types.BOX_PRFT) or
        fourcc.equals(types.BOX_META);
}

/// Reads and validates a single box header at the given file offset.
pub fn readBoxHeader(source: ByteSource, offset: u64) !?BoxHeader {
    if (offset + 8 > source.file_size) return null;

    var header_buf: [8]u8 = undefined;
    const n = try source.readAt(&header_buf, offset);
    if (n < 8) return null;

    const raw_size = std.mem.readInt(u32, header_buf[0..4], .big);
    const fourcc = FourCC{ .bytes = header_buf[4..8].* };

    if (raw_size == 1) {
        // Extended 64-bit size
        if (offset + 16 > source.file_size) return null;
        var ext_buf: [8]u8 = undefined;
        const ext_n = try source.readAt(&ext_buf, offset + 8);
        if (ext_n < 8) return null;

        const large_size = std.mem.readInt(u64, &ext_buf, .big);
        return BoxHeader{
            .fourcc = fourcc,
            .offset = offset,
            .size = large_size,
            .header_size = 16,
            .is_extended_size = true,
            .is_eof_size = false,
        };
    } else if (raw_size == 0) {
        // Box extends to end of file
        const remaining = source.file_size - offset;
        return BoxHeader{
            .fourcc = fourcc,
            .offset = offset,
            .size = remaining,
            .header_size = 8,
            .is_extended_size = false,
            .is_eof_size = true,
        };
    } else {
        return BoxHeader{
            .fourcc = fourcc,
            .offset = offset,
            .size = @as(u64, raw_size),
            .header_size = 8,
            .is_extended_size = false,
            .is_eof_size = false,
        };
    }
}

/// Robust, iterative box tree parser with full structural validation.
pub const SafeBoxParser = struct {
    allocator: std.mem.Allocator,
    max_depth: usize = MAX_NESTING_DEPTH,
    max_boxes: usize = 1024,

    pub fn init(allocator: std.mem.Allocator) SafeBoxParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: SafeBoxParser, source: ByteSource) !ParseResult {
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
            if (header.fourcc.equals(types.BOX_FTYP)) {
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
                    .details = "Stream does not begin with an ftyp box",
                });
            }

            if (header.fourcc.equals(types.BOX_MOOV)) {
                has_moov = true;
                moov_count += 1;
                if (moov_count > 1) {
                    try issues.append(self.allocator, .{
                        .code = .multiple_moov,
                        .offset = curr_offset,
                        .fourcc = header.fourcc,
                        .details = "Multiple moov boxes present in stream",
                    });
                }
            }

            // 5. Build ParsedBox record
            const parent_id: ?u32 = if (stack_len > 0) frame_stack[stack_len - 1].box_id else null;
            const current_id: u32 = @intCast(boxes.items.len);

            var is_full_box = false;
            var fb_version: u8 = 0;
            var fb_flags: u24 = 0;

            if (isStandardFullBox(header.fourcc) and header.payloadSize() >= 4) {
                var fb_buf: [4]u8 = undefined;
                if ((try source.readAt(&fb_buf, header.payloadOffset())) == 4) {
                    is_full_box = true;
                    fb_version = fb_buf[0];
                    fb_flags = (@as(u24, fb_buf[1]) << 16) | (@as(u24, fb_buf[2]) << 8) | @as(u24, fb_buf[3]);
                }
            }

            // Update parent child_count
            if (parent_id) |pid| {
                if (pid < boxes.items.len) {
                    boxes.items[pid].child_count += 1;
                }
            }

            try boxes.append(self.allocator, .{
                .id = current_id,
                .parent_id = parent_id,
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
            const is_container = types.isContainerBox(header.fourcc);
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
