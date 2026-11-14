const std = @import("std");
const common = @import("media_ir").common;
const Region = common.Region;
const ParsedElement = @import("parsed_element.zig").ParsedElement;

/// Converts parsed EBML elements into universal Region representations.
pub fn toRegions(elements: []const ParsedElement, allocator: std.mem.Allocator) ![]Region {
    var regions = try allocator.alloc(Region, elements.len);
    for (elements, 0..) |elem, i| {
        var tag = [_]u8{0} ** 4;
        std.mem.writeInt(u32, &tag, elem.header.id, .big);

        regions[i] = .{
            .id = @intCast(i + 1),
            .parent_id = elem.parent_id,
            .tag = tag,
            .role = switch (elem.role) {
                .header => .header,
                .metadata => .metadata,
                .track_info => .metadata,
                .cluster_index => .index,
                .media_data => .media_data,
                .padding => .padding,
                .unknown => .unknown,
            },
            .header_offset = elem.header.offset,
            .payload_offset = elem.header.offset + elem.header.headerSize(),
            .size = elem.header.totalSize(),
            .depth = elem.depth,
        };
    }
    return regions;
}

pub const toElementSpans = toRegions;
