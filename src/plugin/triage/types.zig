const std = @import("std");

/// Universal gatekeeper decision for triage stages (`Stage 0` generalist and `Stage 1` format-specific).
pub const Verdict = enum(u8) {
    pass,
    flagged,
    drop,

    pub fn asText(self: Verdict) []const u8 {
        return switch (self) {
            .pass => "PASS",
            .flagged => "FLAGGED",
            .drop => "DROP",
        };
    }
};

/// High-efficiency, zero-heap-allocation buffer writer for formatting CSV flags and JSON reports.
pub const FixedBufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) FixedBufWriter {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn written(self: FixedBufWriter) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn writeByte(self: *FixedBufWriter, b: u8) error{NoSpaceLeft}!void {
        if (self.pos >= self.buf.len) return error.NoSpaceLeft;
        self.buf[self.pos] = b;
        self.pos += 1;
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

    pub fn writeJsonEscaped(self: *FixedBufWriter, s: []const u8) error{NoSpaceLeft}!void {
        for (s) |c| {
            switch (c) {
                '"' => try self.writeAll("\\\""),
                '\\' => try self.writeAll("\\\\"),
                '\n' => try self.writeAll("\\n"),
                '\r' => try self.writeAll("\\r"),
                '\t' => try self.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        try self.print("\\u{x:0>4}", .{c});
                    } else {
                        try self.writeByte(c);
                    }
                },
            }
        }
    }
};
