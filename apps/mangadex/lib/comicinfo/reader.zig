const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("schema.zig");
const ComicInfo = schema.ComicInfo;
const ComicPageInfo = schema.ComicPageInfo;
const PageType = schema.PageType;

pub fn unescapeXml(allocator: Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            if (std.mem.startsWith(u8, input[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, input[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, input[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, input[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, input[i..], "&apos;")) {
                try out.append(allocator, '\'');
                i += 6;
            } else {
                try out.append(allocator, input[i]);
                i += 1;
            }
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn parseAttribute(tag_body: []const u8, attr_name: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, tag_body, attr_name) orelse return null;
    const after_key = tag_body[key_pos + attr_name.len ..];
    const eq_pos = std.mem.indexOfScalar(u8, after_key, '=') orelse return null;
    const after_eq = after_key[eq_pos + 1 ..];
    const quote_char: u8 = for (after_eq) |c| {
        if (c == '"' or c == '\'') break c;
        if (c != ' ' and c != '\t') return null;
    } else return null;

    const start = (std.mem.indexOfScalar(u8, after_eq, quote_char) orelse return null) + 1;
    const end = std.mem.indexOfScalar(u8, after_eq[start..], quote_char) orelse return null;
    return after_eq[start .. start + end];
}

pub fn parse(allocator: Allocator, xml: []const u8) !ComicInfo {
    var info = ComicInfo{
        .series = "",
    };
    var pages_list = std.ArrayListUnmanaged(ComicPageInfo).empty;
    errdefer {
        for (pages_list.items) |p| {
            if (p.key) |k| allocator.free(k);
        }
        pages_list.deinit(allocator);
        info.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < xml.len) {
        // Find next '<'
        const tag_open = std.mem.indexOfScalarPos(u8, xml, pos, '<') orelse break;
        pos = tag_open + 1;
        if (pos >= xml.len) break;

        // Skip comments and declarations
        if (std.mem.startsWith(u8, xml[tag_open..], "<!--")) {
            const end_comment = std.mem.indexOfPos(u8, xml, pos, "-->") orelse break;
            pos = end_comment + 3;
            continue;
        }
        if (xml[pos] == '?' or xml[pos] == '!') {
            const end_decl = std.mem.indexOfScalarPos(u8, xml, pos, '>') orelse break;
            pos = end_decl + 1;
            continue;
        }

        // Closing tag of outer elements, e.g. </ComicInfo>
        if (xml[pos] == '/') {
            const end_tag = std.mem.indexOfScalarPos(u8, xml, pos, '>') orelse break;
            pos = end_tag + 1;
            continue;
        }

        // Find end of opening tag '>'
        const tag_close = std.mem.indexOfScalarPos(u8, xml, pos, '>') orelse break;
        const tag_content = xml[pos..tag_close];
        pos = tag_close + 1;

        // Extract tag name (up to whitespace or end)
        var name_end: usize = 0;
        while (name_end < tag_content.len and tag_content[name_end] != ' ' and tag_content[name_end] != '/' and tag_content[name_end] != '\t' and tag_content[name_end] != '\r' and tag_content[name_end] != '\n') {
            name_end += 1;
        }
        const tag_name = tag_content[0..name_end];

        if (std.mem.eql(u8, tag_name, "ComicInfo")) {
            continue;
        }

        // Handle <Pages> section
        if (std.mem.eql(u8, tag_name, "Pages")) {
            const pages_end = std.mem.indexOfPos(u8, xml, pos, "</Pages>") orelse xml.len;
            var p_pos = pos;
            while (p_pos < pages_end) {
                const p_tag_open = std.mem.indexOfPos(u8, xml[0..pages_end], p_pos, "<Page") orelse break;
                const p_tag_close = std.mem.indexOfScalarPos(u8, xml[0..pages_end], p_tag_open, '>') orelse break;
                const p_body = xml[p_tag_open..p_tag_close];
                p_pos = p_tag_close + 1;

                var page_item = ComicPageInfo{
                    .image_index = 0,
                };

                if (parseAttribute(p_body, "Image")) |img_str| {
                    page_item.image_index = std.fmt.parseInt(u32, img_str, 10) catch 0;
                }
                if (parseAttribute(p_body, "Type")) |type_str| {
                    if (std.meta.stringToEnum(PageType, type_str)) |pt| {
                        page_item.page_type = pt;
                    }
                }
                if (parseAttribute(p_body, "DoublePage")) |dp_str| {
                    page_item.double_page = std.mem.eql(u8, dp_str, "true") or std.mem.eql(u8, dp_str, "1");
                }
                if (parseAttribute(p_body, "ImageSize")) |sz_str| {
                    page_item.image_size_bytes = std.fmt.parseInt(u64, sz_str, 10) catch null;
                }
                if (parseAttribute(p_body, "Key")) |k_str| {
                    page_item.key = try unescapeXml(allocator, k_str);
                }

                try pages_list.append(allocator, page_item);
            }
            pos = pages_end + "</Pages>".len;
            continue;
        }

        // Self-closing tags, e.g. <Tag />
        if (tag_content.len > 0 and tag_content[tag_content.len - 1] == '/') {
            continue;
        }

        // Find closing tag </tag_name>
        var close_tag_buf: [128]u8 = undefined;
        const close_tag = std.fmt.bufPrint(&close_tag_buf, "</{s}>", .{tag_name}) catch continue;
        const close_pos = std.mem.indexOfPos(u8, xml, pos, close_tag) orelse continue;

        const val_raw = xml[pos..close_pos];
        pos = close_pos + close_tag.len;
        const val_trimmed = std.mem.trim(u8, val_raw, " \t\r\n");

        if (std.mem.eql(u8, tag_name, "Title")) {
            info.title = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Series")) {
            info.series = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Number")) {
            info.number = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Count")) {
            info.count = std.fmt.parseInt(u32, val_trimmed, 10) catch null;
        } else if (std.mem.eql(u8, tag_name, "Volume")) {
            info.volume = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "AlternateSeries")) {
            info.alternate_series = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Summary")) {
            info.summary = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Notes")) {
            info.notes = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Year")) {
            info.year = std.fmt.parseInt(u16, val_trimmed, 10) catch null;
        } else if (std.mem.eql(u8, tag_name, "Month")) {
            info.month = std.fmt.parseInt(u8, val_trimmed, 10) catch null;
        } else if (std.mem.eql(u8, tag_name, "Day")) {
            info.day = std.fmt.parseInt(u8, val_trimmed, 10) catch null;
        } else if (std.mem.eql(u8, tag_name, "Writer")) {
            info.writer = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Penciller")) {
            info.penciller = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Inker")) {
            info.inker = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Colorist")) {
            info.colorist = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Letterer")) {
            info.letterer = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "CoverArtist")) {
            info.cover_artist = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Editor")) {
            info.editor = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Translator")) {
            info.translator = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Publisher")) {
            info.publisher = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Imprint")) {
            info.imprint = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Genre")) {
            info.genre = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Tags")) {
            info.tags = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "Web")) {
            info.web = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "PageCount")) {
            info.page_count = std.fmt.parseInt(u32, val_trimmed, 10) catch 0;
        } else if (std.mem.eql(u8, tag_name, "LanguageISO")) {
            const unescaped = try unescapeXml(allocator, val_trimmed);
            if (std.mem.eql(u8, unescaped, "en")) {
                allocator.free(unescaped);
                info.language_iso = "en";
            } else {
                info.language_iso = unescaped;
            }
        } else if (std.mem.eql(u8, tag_name, "Format")) {
            info.format = try unescapeXml(allocator, val_trimmed);
        } else if (std.mem.eql(u8, tag_name, "BlackAndWhite")) {
            if (std.meta.stringToEnum(schema.YesNo, val_trimmed)) |bw| {
                info.black_and_white = bw;
            }
        } else if (std.mem.eql(u8, tag_name, "Manga")) {
            if (std.meta.stringToEnum(schema.MangaType, val_trimmed)) |m| {
                info.manga = m;
            }
        } else if (std.mem.eql(u8, tag_name, "AgeRating")) {
            if (std.meta.stringToEnum(schema.AgeRating, val_trimmed)) |ar| {
                info.age_rating = ar;
            }
        }
    }

    if (pages_list.items.len > 0) {
        info.pages = try pages_list.toOwnedSlice(allocator);
    }

    return info;
}
