const std = @import("std");
const Allocator = std.mem.Allocator;
const ByteInterval = @import("byte_interval.zig").ByteInterval;
const IrUnreferencedSlackRow = @import("ir_unreferenced_slack_row.zig").IrUnreferencedSlackRow;

/// Universal calculation of unreferenced gaps/slacks across declared byte intervals.
pub fn computeUnreferencedSlack(
    allocator: Allocator,
    file_size: u64,
    declared_intervals: []const ByteInterval,
) ![]IrUnreferencedSlackRow {
    var slacks: std.ArrayListUnmanaged(IrUnreferencedSlackRow) = .empty;
    errdefer slacks.deinit(allocator);

    if (declared_intervals.len == 0) {
        if (file_size > 0) {
            try slacks.append(allocator, .{
                .slack_id = 1,
                .region_tag = "unreferenced_slack",
                .file_offset = 0,
                .byte_length = file_size,
            });
        }
        return slacks.toOwnedSlice(allocator);
    }

    const sorted = try allocator.dupe(ByteInterval, declared_intervals);
    defer allocator.free(sorted);
    std.mem.sort(ByteInterval, sorted, {}, ByteInterval.lessThan);

    var slack_counter: i64 = 1;
    var cursor: u64 = 0;

    for (sorted) |iv| {
        if (iv.start > cursor) {
            try slacks.append(allocator, .{
                .slack_id = slack_counter,
                .region_tag = "unreferenced_slack",
                .file_offset = cursor,
                .byte_length = iv.start - cursor,
            });
            slack_counter += 1;
        }
        cursor = @max(cursor, iv.end);
    }

    if (cursor < file_size) {
        try slacks.append(allocator, .{
            .slack_id = slack_counter,
            .region_tag = "unreferenced_slack",
            .file_offset = cursor,
            .byte_length = file_size - cursor,
        });
    }

    return slacks.toOwnedSlice(allocator);
}
