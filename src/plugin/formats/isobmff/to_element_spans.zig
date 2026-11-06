const std = @import("std");
const common = @import("vidsec_formats_common");
const Region = common.Region;
const ParsedBox = @import("parsed_box.zig").ParsedBox;

/// Converts parsed ISOBMFF boxes into universal Region representations.
pub fn toRegions(boxes: []const ParsedBox, allocator: std.mem.Allocator) ![]Region {
    var regions = try allocator.alloc(Region, boxes.len);
    for (boxes, 0..) |box, i| {
        regions[i] = .{
            .id = @intCast(i + 1),
            .parent_id = box.parent_id,
            .tag = box.header.fourcc.bytes,
            .role = switch (box.role) {
                .header => .header,
                .metadata => .metadata,
                .media_data => .media_data,
                .index => .index,
                .padding => .padding,
                .unknown => .unknown,
            },
            .header_offset = box.header.offset,
            .payload_offset = box.header.payloadOffset(),
            .size = box.header.size,
            .depth = box.depth,
        };
    }
    return regions;
}

pub const toElementSpans = toRegions;
