const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("schema.zig");
const ComicInfo = schema.ComicInfo;
const ComicPageInfo = schema.ComicPageInfo;

pub fn escapeXml(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }

    return out.toOwnedSlice(allocator);
}

fn appendEscaped(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
}

fn writeTag(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, tag: []const u8, opt_val: ?[]const u8) !void {
    if (opt_val) |val| {
        try out.appendSlice(allocator, "  <");
        try out.appendSlice(allocator, tag);
        try out.appendSlice(allocator, ">");
        try appendEscaped(out, allocator, val);
        try out.appendSlice(allocator, "</");
        try out.appendSlice(allocator, tag);
        try out.appendSlice(allocator, ">\n");
    }
}

fn writeIntTag(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, tag: []const u8, val: anytype) !void {
    var buf: [32]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "  <{s}>{d}</{s}>\n", .{ tag, val, tag });
    try out.appendSlice(allocator, str);
}

fn writeEnumTag(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, tag: []const u8, val: anytype) !void {
    try out.appendSlice(allocator, "  <");
    try out.appendSlice(allocator, tag);
    try out.appendSlice(allocator, ">");
    try out.appendSlice(allocator, @tagName(val));
    try out.appendSlice(allocator, "</");
    try out.appendSlice(allocator, tag);
    try out.appendSlice(allocator, ">\n");
}

pub const ComicInfoWriter = struct {
    pub fn serialize(allocator: Allocator, info: *const ComicInfo) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
        try out.appendSlice(allocator, "<ComicInfo xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n");

        // Core Identification
        try writeTag(&out, allocator, "Title", info.title);
        try writeTag(&out, allocator, "Series", info.series);
        try writeTag(&out, allocator, "Number", info.number);
        if (info.count) |c| try writeIntTag(&out, allocator, "Count", c);
        try writeTag(&out, allocator, "Volume", info.volume);
        try writeTag(&out, allocator, "AlternateSeries", info.alternate_series);

        // Narrative Metadata
        try writeTag(&out, allocator, "Summary", info.summary);
        try writeTag(&out, allocator, "Notes", info.notes);
        if (info.year) |y| try writeIntTag(&out, allocator, "Year", y);
        if (info.month) |m| try writeIntTag(&out, allocator, "Month", m);
        if (info.day) |d| try writeIntTag(&out, allocator, "Day", d);

        // Credits
        try writeTag(&out, allocator, "Writer", info.writer);
        try writeTag(&out, allocator, "Penciller", info.penciller);
        try writeTag(&out, allocator, "Inker", info.inker);
        try writeTag(&out, allocator, "Colorist", info.colorist);
        try writeTag(&out, allocator, "Letterer", info.letterer);
        try writeTag(&out, allocator, "CoverArtist", info.cover_artist);
        try writeTag(&out, allocator, "Editor", info.editor);
        try writeTag(&out, allocator, "Translator", info.translator);

        // Classification & Taxonomy
        try writeTag(&out, allocator, "Publisher", info.publisher);
        try writeTag(&out, allocator, "Imprint", info.imprint);
        try writeTag(&out, allocator, "Genre", info.genre);
        try writeTag(&out, allocator, "Tags", info.tags);
        try writeTag(&out, allocator, "Web", info.web);
        if (info.page_count > 0) try writeIntTag(&out, allocator, "PageCount", info.page_count);
        try writeTag(&out, allocator, "LanguageISO", info.language_iso);

        // Structural Flags
        try writeTag(&out, allocator, "Format", info.format);
        if (info.black_and_white != .Unknown) try writeEnumTag(&out, allocator, "BlackAndWhite", info.black_and_white);
        if (info.manga != .Unknown) try writeEnumTag(&out, allocator, "Manga", info.manga);
        if (info.age_rating != .Unknown) try writeEnumTag(&out, allocator, "AgeRating", info.age_rating);

        // Detailed Page Layout
        if (info.pages.len > 0) {
            try out.appendSlice(allocator, "  <Pages>\n");
            for (info.pages) |page| {
                var pbuf: [128]u8 = undefined;
                const p_start = try std.fmt.bufPrint(&pbuf, "    <Page Image=\"{d}\" Type=\"{s}\"", .{
                    page.image_index,
                    @tagName(page.page_type),
                });
                try out.appendSlice(allocator, p_start);

                if (page.double_page) {
                    try out.appendSlice(allocator, " DoublePage=\"true\"");
                }
                if (page.image_size_bytes) |sz| {
                    var sbuf: [32]u8 = undefined;
                    const s_str = try std.fmt.bufPrint(&sbuf, " ImageSize=\"{d}\"", .{sz});
                    try out.appendSlice(allocator, s_str);
                }
                if (page.key) |k| {
                    try out.appendSlice(allocator, " Key=\"");
                    try appendEscaped(&out, allocator, k);
                    try out.appendSlice(allocator, "\"");
                }
                try out.appendSlice(allocator, " />\n");
            }
            try out.appendSlice(allocator, "  </Pages>\n");
        }

        try out.appendSlice(allocator, "</ComicInfo>\n");
        return out.toOwnedSlice(allocator);
    }
};
