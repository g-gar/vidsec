const ChunkHeader = @import("chunk_header.zig").ChunkHeader;
const ChunkRole = @import("chunk_role.zig").ChunkRole;

/// An indexed chunk in the parsed RIFF container hierarchy.
pub const ParsedChunk = struct {
    id: u32,
    parent_id: ?u32,
    depth: u16,
    header: ChunkHeader,
    role: ChunkRole,
    child_count: u32 = 0,
};
