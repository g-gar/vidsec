const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("../../contract.zig");
const MangaSource = contract.MangaSource;
const SourceMangaSummary = contract.SourceMangaSummary;
const SourceSeriesDetails = contract.SourceSeriesDetails;
const SourceChapter = contract.SourceChapter;
const SourcePageUrl = contract.SourcePageUrl;
const sdk = @import("mangadex_sdk");
const MangaDexClient = sdk.MangaDexClient;
const RelationshipType = sdk.RelationshipType;
const SortOrder = sdk.SortOrder;
const buildPageUrl = sdk.buildPageUrl;
const buildCoverUrl = sdk.buildCoverUrl;

const source_id = "mangadex";
const mangadex_host = "mangadex.org";
const default_title = "Untitled";
const default_status = "ongoing";
const manga_includes = [_][]const u8{
    RelationshipType.cover_art.asStr(),
    RelationshipType.author.asStr(),
    RelationshipType.artist.asStr(),
};
const chapter_includes = [_][]const u8{
    RelationshipType.scanlation_group.asStr(),
};

pub const MangaDexSource = struct {
    client: *MangaDexClient,

    comptime {
        MangaSource.assertImplements(@This());
    }

    pub fn init(client: *MangaDexClient) MangaDexSource {
        return .{ .client = client };
    }

    pub fn mangaSource(self: *MangaDexSource) MangaSource {
        return .{
            .ptr = self,
            .vtable = &.{
                .getSourceId = getSourceIdBridge,
                .search = searchBridge,
                .getDetails = getDetailsBridge,
                .getChapters = getChaptersBridge,
                .getPageUrls = getPageUrlsBridge,
                .canHandle = canHandleBridge,
            },
        };
    }

    fn getSourceIdBridge(_: *anyopaque) []const u8 {
        return source_id;
    }

    fn canHandleBridge(_: *anyopaque, identifier: []const u8) bool {
        if (std.mem.indexOf(u8, identifier, mangadex_host) != null) return true;
        if (identifier.len == 36 and
            identifier[8] == '-' and
            identifier[13] == '-' and
            identifier[18] == '-' and
            identifier[23] == '-')
        {
            return true;
        }
        return false;
    }

    fn searchBridge(ctx: *anyopaque, allocator: Allocator, query: []const u8) anyerror![]SourceMangaSummary {
        const self: *MangaDexSource = @ptrCast(@alignCast(ctx));
        var res = try self.client.searchManga(.{
            .title = query,
            .limit = 20,
            .includes = &manga_includes,
        });
        defer res.deinit();

        var list = try allocator.alloc(SourceMangaSummary, res.items.len);
        errdefer {
            for (list) |*item| {
                if (item.source_series_id.len > 0) allocator.free(item.source_series_id);
                if (item.title.len > 0) allocator.free(item.title);
                if (item.cover_url) |c| allocator.free(c);
            }
            allocator.free(list);
        }

        for (res.items, 0..) |item, idx| {
            const canonical_title = item.attributes.title.getPrimary() orelse default_title;
            const owned_id = try allocator.dupe(u8, item.id);
            const owned_title = try allocator.dupe(u8, canonical_title);

            var cover_url: ?[]const u8 = null;
            for (item.relationships) |rel| {
                if (rel.kind() == .cover_art) {
                    if (rel.attrString(.fileName)) |fn_str| {
                        cover_url = buildCoverUrl(allocator, item.id, fn_str, .medium_512) catch null;
                    }
                    break;
                }
            }

            list[idx] = .{
                .source_id = source_id,
                .source_series_id = owned_id,
                .title = owned_title,
                .cover_url = cover_url,
            };
        }

        return list;
    }

    fn getDetailsBridge(ctx: *anyopaque, allocator: Allocator, source_series_id: []const u8) anyerror!SourceSeriesDetails {
        const self: *MangaDexSource = @ptrCast(@alignCast(ctx));
        var res = try self.client.getManga(source_series_id, &manga_includes);
        defer res.deinit();

        const item = res.data;
        const title = try allocator.dupe(u8, item.attributes.title.getPrimary() orelse default_title);
        errdefer allocator.free(title);

        var alt_list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (alt_list.items) |a| allocator.free(a);
            alt_list.deinit(allocator);
        }

        for (item.attributes.altTitles) |alt_map| {
            if (alt_map.raw == .object) {
                var it = alt_map.raw.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        const alt_str = try allocator.dupe(u8, entry.value_ptr.*.string);
                        try alt_list.append(allocator, alt_str);
                    }
                }
            }
        }
        const owned_alt_titles = try alt_list.toOwnedSlice(allocator);
        errdefer {
            for (owned_alt_titles) |a| allocator.free(a);
            allocator.free(owned_alt_titles);
        }

        var lang_list = try allocator.alloc([]const u8, item.attributes.availableTranslatedLanguages.len);
        errdefer {
            for (lang_list) |l| allocator.free(l);
            allocator.free(lang_list);
        }
        for (item.attributes.availableTranslatedLanguages, 0..) |l, i| {
            lang_list[i] = try allocator.dupe(u8, l);
        }
        errdefer {
            for (lang_list) |l| allocator.free(l);
            allocator.free(lang_list);
        }

        var summary: ?[]const u8 = null;
        if (item.attributes.description) |desc| {
            if (desc.getPrimary()) |s| {
                summary = try allocator.dupe(u8, s);
            }
        }
        errdefer if (summary) |s| allocator.free(s);

        const status = try allocator.dupe(u8, item.attributes.status orelse default_status);
        errdefer allocator.free(status);

        var author: ?[]const u8 = null;
        var artist: ?[]const u8 = null;
        var cover_url: ?[]const u8 = null;

        for (item.relationships) |rel| {
            switch (rel.kind() orelse continue) {
                .author => if (rel.attrString(.name)) |s| {
                    author = try allocator.dupe(u8, s);
                },
                .artist => if (rel.attrString(.name)) |s| {
                    artist = try allocator.dupe(u8, s);
                },
                .cover_art => if (rel.attrString(.fileName)) |fn_str| {
                    cover_url = buildCoverUrl(allocator, item.id, fn_str, .original) catch null;
                },
                else => {},
            }
        }

        return .{
            .title = title,
            .alt_titles = owned_alt_titles,
            .available_languages = lang_list,
            .summary = summary,
            .author = author,
            .artist = artist,
            .status = status,
            .year = item.attributes.year,
            .cover_url = cover_url,
        };
    }

    fn getChaptersBridge(ctx: *anyopaque, allocator: Allocator, source_series_id: []const u8, lang: []const u8) anyerror![]SourceChapter {
        const self: *MangaDexSource = @ptrCast(@alignCast(ctx));
        var all_chapters: std.ArrayListUnmanaged(SourceChapter) = .empty;
        errdefer {
            for (all_chapters.items) |*ch| {
                if (ch.source_chapter_id.len > 0) allocator.free(ch.source_chapter_id);
                if (ch.chapter_number.len > 0) allocator.free(ch.chapter_number);
                if (ch.volume_number) |v| allocator.free(v);
                if (ch.title) |t| allocator.free(t);
                if (ch.language_iso.len > 0) allocator.free(ch.language_iso);
                if (ch.scanlation_group) |g| allocator.free(g);
            }
            all_chapters.deinit(allocator);
        }

        var offset: u32 = 0;
        const page_limit: u32 = 100;

        while (true) {
            var res = try self.client.getMangaFeed(source_series_id, .{
                .limit = page_limit,
                .offset = offset,
                .translatedLanguage = &.{lang},
                .includes = &chapter_includes,
                .order_chapter = SortOrder.asc.asStr(),
            });
            defer res.deinit();

            if (res.items.len == 0) break;

            for (res.items) |item| {
                const ch_id = try allocator.dupe(u8, item.id);
                errdefer allocator.free(ch_id);
                const ch_num = try allocator.dupe(u8, item.attributes.chapter orelse "");
                errdefer allocator.free(ch_num);
                const vol = if (item.attributes.volume) |v| try allocator.dupe(u8, v) else null;
                errdefer if (vol) |v| allocator.free(v);
                const title = if (item.attributes.title) |t| try allocator.dupe(u8, t) else null;
                errdefer if (title) |t| allocator.free(t);
                const lang_iso = try allocator.dupe(u8, item.attributes.translatedLanguage);
                errdefer allocator.free(lang_iso);

                var group: ?[]const u8 = null;
                for (item.relationships) |rel| {
                    if (rel.kind() == .scanlation_group) {
                        if (rel.attrString(.name)) |s| {
                            group = try allocator.dupe(u8, s);
                        }
                        break;
                    }
                }

                try all_chapters.append(allocator, .{
                    .source_chapter_id = ch_id,
                    .chapter_number = ch_num,
                    .volume_number = vol,
                    .title = title,
                    .language_iso = lang_iso,
                    .scanlation_group = group,
                    .page_count = item.attributes.pages,
                });
            }

            offset += @intCast(res.items.len);
            if (res.items.len < page_limit or (res.total > 0 and offset >= res.total)) {
                break;
            }
        }

        return all_chapters.toOwnedSlice(allocator);
    }

    fn getPageUrlsBridge(ctx: *anyopaque, allocator: Allocator, source_chapter_id: []const u8) anyerror![]SourcePageUrl {
        const self: *MangaDexSource = @ptrCast(@alignCast(ctx));
        var res = try self.client.getAtHomeServer(source_chapter_id, false);
        defer res.deinit();

        const data_pages = res.chapter.data;
        var list = try allocator.alloc(SourcePageUrl, data_pages.len);
        errdefer {
            for (list) |*p| {
                if (p.url.len > 0) allocator.free(p.url);
            }
            allocator.free(list);
        }

        for (data_pages, 0..) |filename, idx| {
            const page_url = try buildPageUrl(allocator, res.baseUrl, false, res.chapter.hash, filename);
            list[idx] = .{
                .page_number = @intCast(idx + 1),
                .url = page_url,
                .headers = &.{},
            };
        }

        return list;
    }
};
