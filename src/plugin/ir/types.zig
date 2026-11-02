const std = @import("std");
const abi = @import("vidsec_abi");

/// Canonical structural roles for IR regions.
pub const RegionRole = enum {
    header,
    container,
    metadata,
    media_data,
    index,
    padding,
    unknown,

    pub fn asText(self: RegionRole) []const u8 {
        return switch (self) {
            .header => "header",
            .container => "container",
            .metadata => "metadata",
            .media_data => "media_data",
            .index => "index",
            .padding => "padding",
            .unknown => "unknown",
        };
    }

    pub fn parse(s: []const u8) RegionRole {
        if (std.mem.eql(u8, s, "header")) return .header;
        if (std.mem.eql(u8, s, "container")) return .container;
        if (std.mem.eql(u8, s, "metadata")) return .metadata;
        if (std.mem.eql(u8, s, "media_data")) return .media_data;
        if (std.mem.eql(u8, s, "index")) return .index;
        if (std.mem.eql(u8, s, "padding")) return .padding;
        return .unknown;
    }
};

/// High-efficiency zero-heap buffer writer.
pub const FixedBufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) FixedBufWriter {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn written(self: FixedBufWriter) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn writeAll(self: *FixedBufWriter, s: []const u8) error{NoSpaceLeft}!void {
        if (self.pos + s.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos .. self.pos + s.len], s);
        self.pos += s.len;
    }

    pub fn print(self: *FixedBufWriter, comptime fmt_str: []const u8, args: anytype) error{NoSpaceLeft}!void {
        const slice = std.fmt.bufPrint(self.buf[self.pos..], fmt_str, args) catch return error.NoSpaceLeft;
        self.pos += slice.len;
    }
};
