const std = @import("std");
const common = @import("vidsec_formats_common");
const ByteSource = common.ByteSource;
const ElementHeader = @import("element_header.zig").ElementHeader;
const vint = @import("vint.zig");

/// Reads an element header at `offset` using `vint.readElementId` and `vint.readDataSize`.
pub fn readElementHeader(source: ByteSource, offset: u64) !?ElementHeader {
    if (offset >= source.file_size) return null;

    const id_res = (try vint.readElementId(source, offset)) orelse return null;
    const size_offset = offset + id_res.len;
    if (size_offset >= source.file_size) return null;

    const size_res = (try vint.readDataSize(source, size_offset)) orelse return null;

    return ElementHeader{
        .id = id_res.id,
        .id_len = id_res.len,
        .data_size = size_res.size,
        .size_len = size_res.len,
        .offset = offset,
        .is_unknown_size = size_res.is_unknown,
    };
}
