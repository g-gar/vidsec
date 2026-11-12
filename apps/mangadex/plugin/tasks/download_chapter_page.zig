const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const sdk = @import("mangadex_sdk");
const HttpTransport = sdk.HttpTransport;
const ChapterPageItem = @import("fetch_chapter_pages.zig").ChapterPageItem;

pub const DownloadedPageItem = struct {
    source_chapter_id: []const u8,
    series_id: []const u8 = "",
    chapter_number: []const u8 = "",
    page_number: u32,
    url: []const u8,
    image_data: []const u8,
};

/// Service that downloads a single chapter page image via HTTP
/// and returns a DownloadedPageItem containing the raw image bytes.
pub const DownloadChapterPageService = struct {
    http: HttpTransport,
    logger: Logger,

    pub fn execute(self: *DownloadChapterPageService, alloc: Allocator, item: ChapterPageItem) !DownloadedPageItem {
        if (item.url.len == 0) {
            self.logger.err("Page {d} in chapter '{s}' has an empty URL", .{
                item.page_number,
                item.source_chapter_id,
            });
            return error.EmptyPageUrl;
        }

        self.logger.info("Downloading page {d} from '{s}'", .{ item.page_number, item.url });

        var attempts: usize = 0;
        const max_attempts: usize = 8;
        const resp = while (attempts < max_attempts) : (attempts += 1) {
            const r = self.http.execute(alloc, .GET, item.url, &.{}, &.{}) catch |err| {
                if (err == error.RateLimited and attempts + 1 < max_attempts) {
                    const wait_ms = @as(u64, @intCast(attempts + 1)) * 150;
                    var ts: std.c.timespec = .{
                        .sec = @intCast(wait_ms / 1000),
                        .nsec = @intCast((wait_ms % 1000) * 1000 * 1000),
                    };
                    _ = std.c.nanosleep(&ts, null);
                    continue;
                }
                return err;
            };
            break r;
        } else return error.RateLimited;

        if (resp.status_code < 200 or resp.status_code >= 300) {
            self.logger.err("HTTP {d} received while downloading page {d} from '{s}'", .{
                resp.status_code,
                item.page_number,
                item.url,
            });
            return error.HttpDownloadFailed;
        }

        if (resp.body.len == 0) {
            self.logger.err("Received empty image payload for page {d} from '{s}'", .{
                item.page_number,
                item.url,
            });
            return error.EmptyImagePayload;
        }

        return DownloadedPageItem{
            .source_chapter_id = try alloc.dupe(u8, item.source_chapter_id),
            .series_id = try alloc.dupe(u8, item.series_id),
            .chapter_number = try alloc.dupe(u8, item.chapter_number),
            .page_number = item.page_number,
            .url = try alloc.dupe(u8, item.url),
            .image_data = resp.body,
        };
    }
};
