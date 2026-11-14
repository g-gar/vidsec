const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const DownloadedPageItem = @import("download_chapter_page.zig").DownloadedPageItem;

pub const PageWithContentType = struct {
    source_chapter_id: []const u8,
    series_id: []const u8 = "",
    chapter_number: []const u8 = "",
    page_number: u32,
    url: []const u8,
    image_data: []const u8,
    content_type: []const u8,
};

/// Pure domain service dedicated to detecting content types of image payloads by inspecting magic bytes.
pub const DetectContentTypeService = struct {
    logger: Logger,

    /// Static zero-allocation helper to detect MIME types from binary headers.
    pub fn detect(data: []const u8) []const u8 {
        if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) {
            return "image/png";
        }
        if (data.len >= 3 and std.mem.eql(u8, data[0..3], "\xff\xd8\xff")) {
            return "image/jpeg";
        }
        if (data.len >= 12 and std.mem.startsWith(u8, data, "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) {
            return "image/webp";
        }
        if (data.len >= 6 and (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a"))) {
            return "image/gif";
        }
        if (data.len >= 4 and std.mem.eql(u8, data[0..4], "<svg") or (data.len >= 5 and std.mem.eql(u8, data[0..5], "<?xml"))) {
            return "image/svg+xml";
        }
        return "application/octet-stream";
    }

    pub fn execute(self: *DetectContentTypeService, alloc: Allocator, item: DownloadedPageItem) !PageWithContentType {
        if (item.image_data.len == 0) {
            self.logger.err("Cannot detect content type: empty image payload for page {d}", .{item.page_number});
            return error.EmptyImagePayload;
        }

        const ct = detect(item.image_data);
        self.logger.info("Page {d} content type detected as '{s}' ({d} bytes)", .{
            item.page_number,
            ct,
            item.image_data.len,
        });

        return PageWithContentType{
            .source_chapter_id = try alloc.dupe(u8, item.source_chapter_id),
            .series_id = try alloc.dupe(u8, item.series_id),
            .chapter_number = try alloc.dupe(u8, item.chapter_number),
            .page_number = item.page_number,
            .url = try alloc.dupe(u8, item.url),
            .image_data = item.image_data,
            .content_type = ct,
        };
    }
};
