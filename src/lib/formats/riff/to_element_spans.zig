const std = @import("std");
const common = @import("vidsec_formats_common");
const Region = common.Region;
const ParsedChunk = @import("parsed_chunk.zig").ParsedChunk;

/// Converts parsed RIFF chunks into universal Region representations.
pub fn toRegions(chunks: []const ParsedChunk, allocator: std.mem.Allocator) ![]Region {
    var regions = try allocator.alloc(Region, chunks.len);
    for (chunks, 0..) |chunk, i| {
        regions[i] = .{
            .id = @intCast(i + 1),
            .parent_id = chunk.parent_id,
            .tag = chunk.header.fourcc.bytes,
            .role = switch (chunk.role) {
                .header => .header,
                .metadata => .metadata,
                .stream_header => .metadata,
                .media_data => .media_data,
                .index => .index,
                .padding => .padding,
                .unknown => .unknown,
            },
            .header_offset = chunk.header.offset,
            .payload_offset = chunk.header.offset + chunk.header.headerSize(),
            .size = chunk.header.totalSize(),
            .depth = chunk.depth,
        };
    }
    return regions;
}

pub const toElementSpans = toRegions;
