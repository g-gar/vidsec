const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const zip_archive = @import("zip_archive");
const ZipArchiveWriter = zip_archive.ZipArchiveWriter;
const PageWithContentType = @import("detect_content_type.zig").PageWithContentType;

const c_stat = @cImport({
    @cInclude("sys/stat.h");
});

fn ensureParentDirs(alloc: Allocator, path: []const u8) void {
    const slash_idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash_idx == 0) return;
    const parent = path[0..slash_idx];

    var it = std.mem.splitScalar(u8, parent, '/');
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    if (parent[0] == '/') {
        buf.append(alloc, '/') catch return;
    }

    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
            if (seg.len > 0) {
                buf.appendSlice(alloc, seg) catch return;
                buf.append(alloc, '/') catch return;
            }
            continue;
        }
        buf.appendSlice(alloc, seg) catch return;
        if (alloc.dupeZ(u8, buf.items)) |dir_z| {
            defer alloc.free(dir_z);
            _ = c_stat.mkdir(dir_z.ptr, 0o755);
        } else |_| return;
        buf.append(alloc, '/') catch return;
    }
}

pub const BuildCbzArchiveInputs = struct {
    pages: []const PageWithContentType,
    comic_info_xml: ?[]const u8 = null,
    output_dir: []const u8 = "./output/cbz",
    output_path: ?[]const u8 = null,
};

pub const CbzArchiveOutput = struct {
    archive_path: []const u8,
    total_pages: u32,
    file_size_bytes: u64,
};

fn extensionForContentType(ct: []const u8) []const u8 {
    if (std.mem.eql(u8, ct, "image/png")) return "png";
    if (std.mem.eql(u8, ct, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, ct, "image/webp")) return "webp";
    if (std.mem.eql(u8, ct, "image/gif")) return "gif";
    return "bin";
}

fn replacePlaceholders(alloc: Allocator, template: []const u8, chapter_num: []const u8, series_id: []const u8) ![]const u8 {
    var replaced: std.ArrayListUnmanaged(u8) = .empty;
    errdefer replaced.deinit(alloc);
    var rem = template;

    while (rem.len > 0) {
        if (std.mem.startsWith(u8, rem, "{chapter}")) {
            try replaced.appendSlice(alloc, chapter_num);
            rem = rem["{chapter}".len..];
        } else if (std.mem.startsWith(u8, rem, "{series}")) {
            try replaced.appendSlice(alloc, series_id);
            rem = rem["{series}".len..];
        } else {
            try replaced.append(alloc, rem[0]);
            rem = rem[1..];
        }
    }
    return replaced.toOwnedSlice(alloc);
}

fn customizeComicInfo(alloc: Allocator, base_xml: []const u8, chapter_num: []const u8, page_count: u32) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(alloc);

    var xml = base_xml;
    var had_number = false;

    // 1. Replace <Number>...</Number> if present
    if (std.mem.indexOf(u8, xml, "<Number>")) |num_start| {
        if (std.mem.indexOf(u8, xml[num_start..], "</Number>")) |num_end_rel| {
            had_number = true;
            const num_end = num_start + num_end_rel + "</Number>".len;
            try result.appendSlice(alloc, xml[0..num_start]);
            try result.appendSlice(alloc, "<Number>");
            try result.appendSlice(alloc, chapter_num);
            try result.appendSlice(alloc, "</Number>");
            xml = xml[num_end..];
        }
    }

    // 2. Insert <Number> (if absent) and <PageCount> before </ComicInfo>
    if (std.mem.indexOf(u8, xml, "</ComicInfo>")) |close_idx| {
        try result.appendSlice(alloc, xml[0..close_idx]);
        if (!had_number and std.mem.indexOf(u8, result.items, "<Number>") == null) {
            const num_tag = try std.fmt.allocPrint(alloc, "  <Number>{s}</Number>\n", .{chapter_num});
            defer alloc.free(num_tag);
            try result.appendSlice(alloc, num_tag);
        }
        if (std.mem.indexOf(u8, result.items, "<PageCount>") == null) {
            const pc_tag = try std.fmt.allocPrint(alloc, "  <PageCount>{d}</PageCount>\n", .{page_count});
            defer alloc.free(pc_tag);
            try result.appendSlice(alloc, pc_tag);
        }
        try result.appendSlice(alloc, "</ComicInfo>");
    } else {
        try result.appendSlice(alloc, xml);
    }

    return result.toOwnedSlice(alloc);
}

/// Service that bundles comic page image streams and optional ComicInfo.xml metadata
/// into standard per-chapter .cbz (ZIP) archives using STORE compression for maximum throughput.
pub const BuildCbzArchiveService = struct {
    logger: Logger,

    pub fn execute(self: *BuildCbzArchiveService, alloc: Allocator, inputs: BuildCbzArchiveInputs) !CbzArchiveOutput {
        if (inputs.pages.len == 0) {
            self.logger.warn("Cannot build CBZ archive: no pages provided", .{});
            const fallback_path = inputs.output_path orelse inputs.output_dir;
            return CbzArchiveOutput{
                .archive_path = try alloc.dupe(u8, fallback_path),
                .total_pages = 0,
                .file_size_bytes = 0,
            };
        }

        const ChapterGroup = struct {
            chapter_number: []const u8,
            pages: std.ArrayListUnmanaged(PageWithContentType) = .empty,
        };

        var groups: std.ArrayListUnmanaged(ChapterGroup) = .empty;
        defer {
            for (groups.items) |*g| g.pages.deinit(alloc);
            groups.deinit(alloc);
        }

        for (inputs.pages) |page| {
            const ch_num = if (page.chapter_number.len > 0) page.chapter_number else "1";
            var found: ?*ChapterGroup = null;
            for (groups.items) |*g| {
                if (std.mem.eql(u8, g.chapter_number, ch_num)) {
                    found = g;
                    break;
                }
            }
            if (found == null) {
                try groups.append(alloc, .{
                    .chapter_number = ch_num,
                    .pages = .empty,
                });
                found = &groups.items[groups.items.len - 1];
            }
            try found.?.pages.append(alloc, page);
        }

        const PageSortCtx = struct {
            pub fn lessThan(_: @This(), a: PageWithContentType, b: PageWithContentType) bool {
                return a.page_number < b.page_number;
            }
        };

        var last_archive_path: []const u8 = "";
        var total_size_bytes: u64 = 0;

        for (groups.items) |*group| {
            std.mem.sort(PageWithContentType, group.pages.items, PageSortCtx{}, PageSortCtx.lessThan);

            const series_id = if (group.pages.items.len > 0) group.pages.items[0].series_id else "";

            const archive_path = if (inputs.output_path) |op| blk: {
                if (std.mem.indexOf(u8, op, "{chapter}") != null or std.mem.indexOf(u8, op, "{series}") != null) {
                    break :blk try replacePlaceholders(alloc, op, group.chapter_number, series_id);
                } else if (groups.items.len == 1 and std.mem.endsWith(u8, op, ".cbz")) {
                    break :blk try alloc.dupe(u8, op);
                } else {
                    const resolved_dir = try replacePlaceholders(alloc, inputs.output_dir, group.chapter_number, series_id);
                    defer alloc.free(resolved_dir);
                    break :blk try std.fmt.allocPrint(alloc, "{s}/chapter_{s}.cbz", .{ resolved_dir, group.chapter_number });
                }
            } else blk: {
                const resolved_dir = try replacePlaceholders(alloc, inputs.output_dir, group.chapter_number, series_id);
                defer alloc.free(resolved_dir);
                break :blk try std.fmt.allocPrint(alloc, "{s}/chapter_{s}.cbz", .{ resolved_dir, group.chapter_number });
            };

            self.logger.info("Building CBZ archive '{s}' with {d} pages", .{
                archive_path,
                group.pages.items.len,
            });

            ensureParentDirs(alloc, archive_path);

            var writer = try ZipArchiveWriter.create(alloc, archive_path);
            defer writer.deinit();

            // 1. Add ComicInfo.xml if present (deflated compression)
            if (inputs.comic_info_xml) |base_xml| {
                if (base_xml.len > 0) {
                    const tailored = try customizeComicInfo(alloc, base_xml, group.chapter_number, @intCast(group.pages.items.len));
                    defer alloc.free(tailored);
                    self.logger.info("Adding ComicInfo.xml to CBZ archive (chapter: {s}, {d} bytes)", .{ group.chapter_number, tailored.len });
                    try writer.addFileFromMemory("ComicInfo.xml", tailored, .default);
                }
            }

            // 2. Add each page image in STORE mode
            for (group.pages.items, 0..) |page, idx| {
                const ext = extensionForContentType(page.content_type);
                const page_idx = if (page.page_number > 0) page.page_number else @as(u32, @intCast(idx + 1));
                const entry_name = try std.fmt.allocPrint(alloc, "{d:0>3}.{s}", .{ page_idx, ext });
                defer alloc.free(entry_name);
                try writer.addFileFromMemory(entry_name, page.image_data, .store);
            }

            try writer.finish();

            const path_z = try alloc.dupeZ(u8, archive_path);
            defer alloc.free(path_z);
            var st: c_stat.struct_stat = undefined;
            var file_size: u64 = 0;
            if (c_stat.stat(path_z.ptr, &st) == 0) {
                file_size = @intCast(st.st_size);
            }
            total_size_bytes += file_size;

            self.logger.info("Successfully created CBZ archive '{s}' ({d} bytes, {d} pages)", .{
                archive_path,
                file_size,
                group.pages.items.len,
            });

            last_archive_path = archive_path;
        }

        return CbzArchiveOutput{
            .archive_path = last_archive_path,
            .total_pages = @intCast(inputs.pages.len),
            .file_size_bytes = total_size_bytes,
        };
    }
};
