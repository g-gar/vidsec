const std = @import("std");
const types = @import("types.zig");

pub const ByteSource = types.ByteSource;
pub const Vint = types.Vint;

pub const VintError = error{
    InvalidLeadingZeros,
    UnexpectedEof,
    ExceedsMaxOctets,
};

/// Decodes a VINT from an in-memory byte slice. Returns null if slice is empty or invalid.
pub fn readVintSlice(buf: []const u8) ?Vint {
    if (buf.len == 0) return null;
    const first_byte = buf[0];
    if (first_byte == 0x00) return null; // 8 leading zeros is illegal (len > 8)

    const len: u8 = @clz(first_byte) + 1;
    if (len > 8 or len > buf.len) return null;

    var raw: u64 = 0;
    for (buf[0..len]) |b| {
        raw = (raw << 8) | b;
    }

    const marker_bit: u64 = @as(u64, 1) << @intCast(7 * len);
    const mask = marker_bit - 1;
    const data_val = raw & mask;
    const is_all_ones = (data_val == mask);

    return Vint{
        .raw_value = raw,
        .length = len,
        .data_value = data_val,
        .is_all_ones = is_all_ones,
    };
}

/// Reads a VINT from a `ByteSource` at the specified file offset.
pub fn readVint(source: ByteSource, offset: u64) !?Vint {
    if (offset >= source.file_size) return null;

    var first_byte_buf: [1]u8 = undefined;
    const n = try source.readAt(&first_byte_buf, offset);
    if (n < 1) return null;

    const first_byte = first_byte_buf[0];
    if (first_byte == 0x00) return null;

    const len: u8 = @clz(first_byte) + 1;
    if (len > 8) return null;
    if (offset + len > source.file_size) return null;

    var octets_buf: [8]u8 = undefined;
    const read_n = try source.readAt(octets_buf[0..len], offset);
    if (read_n < len) return null;

    var raw: u64 = 0;
    for (octets_buf[0..len]) |b| {
        raw = (raw << 8) | b;
    }

    const marker_bit: u64 = @as(u64, 1) << @intCast(7 * len);
    const mask = marker_bit - 1;
    const data_val = raw & mask;
    const is_all_ones = (data_val == mask);

    return Vint{
        .raw_value = raw,
        .length = len,
        .data_value = data_val,
        .is_all_ones = is_all_ones,
    };
}

/// Reads an Element ID (1 to 4 octets) retaining the length-marker bit.
pub fn readElementId(source: ByteSource, offset: u64) !?struct { id: u32, len: u8 } {
    const vint = (try readVint(source, offset)) orelse return null;
    if (vint.length > 4) return null; // Standard EBML Element IDs cannot exceed 4 octets
    return .{
        .id = @truncate(vint.raw_value),
        .len = vint.length,
    };
}

/// Reads a Data Size VINT (1 to 8 octets) with length-marker bit masked off.
pub fn readDataSize(source: ByteSource, offset: u64) !?struct { size: u64, len: u8, is_unknown: bool } {
    const vint = (try readVint(source, offset)) orelse return null;
    return .{
        .size = vint.data_value,
        .len = vint.length,
        .is_unknown = vint.is_all_ones,
    };
}

/// Reads a big-endian unsigned integer of 1 to 8 bytes from `source`.
pub fn readUint(source: ByteSource, offset: u64, size: u64) !u64 {
    if (size == 0 or size > 8) return 0;
    if (offset + size > source.file_size) return error.UnexpectedEof;

    var buf: [8]u8 = undefined;
    const n = try source.readAt(buf[0..size], offset);
    if (n < size) return error.UnexpectedEof;

    var val: u64 = 0;
    for (buf[0..size]) |b| {
        val = (val << 8) | b;
    }
    return val;
}

/// Reads a 4-byte (f32) or 8-byte (f64) IEEE-754 float from `source`.
pub fn readFloat(source: ByteSource, offset: u64, size: u64) !f64 {
    if (offset + size > source.file_size) return 0.0;

    if (size == 4) {
        var buf: [4]u8 = undefined;
        if ((try source.readAt(&buf, offset)) < 4) return 0.0;
        const bits = std.mem.readInt(u32, &buf, .big);
        return @floatCast(@as(f32, @bitCast(bits)));
    } else if (size == 8) {
        var buf: [8]u8 = undefined;
        if ((try source.readAt(&buf, offset)) < 8) return 0.0;
        const bits = std.mem.readInt(u64, &buf, .big);
        return @bitCast(bits);
    }
    return 0.0;
}

/// Reads a string into `buf` and returns the trimmed slice.
pub fn readString(source: ByteSource, buf: []u8, offset: u64, size: u64) ![]const u8 {
    if (size == 0) return "";
    const to_read = @min(buf.len, size);
    if (offset + to_read > source.file_size) return "";

    const n = try source.readAt(buf[0..to_read], offset);
    if (n == 0) return "";
    var len = n;
    while (len > 0 and buf[len - 1] == 0) len -= 1;
    return buf[0..len];
}
