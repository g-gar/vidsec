const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("contract.zig");
const MangaSource = contract.MangaSource;

/// Central registry managing polymorphic MangaSource providers.
/// Enables dynamic dispatching of catalog queries, metadata scraping,
/// and chapter downloads based on datasource identifiers.
pub const SourceRegistry = struct {
    sources: std.StringHashMapUnmanaged(MangaSource) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) SourceRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SourceRegistry) void {
        self.sources.deinit(self.allocator);
    }

    /// Registers a MangaSource instance indexed by its unique `source_id`.
    pub fn register(self: *SourceRegistry, source: MangaSource) !void {
        try self.sources.put(self.allocator, source.getSourceId(), source);
    }

    /// Retrieves an active MangaSource by its unique `source_id`.
    pub fn get(self: *const SourceRegistry, source_id: []const u8) ?MangaSource {
        return self.sources.get(source_id);
    }

    /// Checks if a source with the specified id is registered.
    pub fn has(self: *const SourceRegistry, source_id: []const u8) bool {
        return self.sources.contains(source_id);
    }

    /// Finds the first registered provider that can handle the given series identifier or URL.
    pub fn findByCanHandle(self: *const SourceRegistry, identifier: []const u8) ?MangaSource {
        var it = self.sources.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.canHandle(identifier)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    /// Returns the number of registered sources.
    pub fn count(self: *const SourceRegistry) usize {
        return self.sources.count();
    }
};

test "SourceRegistry: register, get, and duplicate check" {
    const testing = std.testing;
    var reg = SourceRegistry.init(testing.allocator);
    defer reg.deinit();

    try testing.expectEqual(@as(usize, 0), reg.count());
    try testing.expect(!reg.has("mangadex"));

    const DummySource = struct {
        id: []const u8,

        pub fn mangaSource(self: *@This()) MangaSource {
            return .{
                .ptr = self,
                .vtable = &.{
                    .getSourceId = getSourceIdBridge,
                    .search = searchBridge,
                    .getDetails = getDetailsBridge,
                    .getChapters = getChaptersBridge,
                    .getPageUrls = getPageUrlsBridge,
                },
            };
        }

        fn getSourceIdBridge(ctx: *anyopaque) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.id;
        }

        fn searchBridge(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]contract.SourceMangaSummary {
            return &.{};
        }

        fn getDetailsBridge(_: *anyopaque, _: Allocator, _: []const u8) anyerror!contract.SourceSeriesDetails {
            return error.NotImplemented;
        }

        fn getChaptersBridge(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror![]contract.SourceChapter {
            return &.{};
        }

        fn getPageUrlsBridge(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]contract.SourcePageUrl {
            return &.{};
        }

        fn canHandleBridge(ctx: *anyopaque, identifier: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return std.mem.indexOf(u8, identifier, self.id) != null;
        }
    };

    var src1 = DummySource{ .id = "mangadex" };
    var src2 = DummySource{ .id = "tmo_scraper" };

    const src1_ms = MangaSource{
        .ptr = &src1,
        .vtable = &.{
            .getSourceId = DummySource.getSourceIdBridge,
            .search = DummySource.searchBridge,
            .getDetails = DummySource.getDetailsBridge,
            .getChapters = DummySource.getChaptersBridge,
            .getPageUrls = DummySource.getPageUrlsBridge,
            .canHandle = DummySource.canHandleBridge,
        },
    };

    const src2_ms = MangaSource{
        .ptr = &src2,
        .vtable = &.{
            .getSourceId = DummySource.getSourceIdBridge,
            .search = DummySource.searchBridge,
            .getDetails = DummySource.getDetailsBridge,
            .getChapters = DummySource.getChaptersBridge,
            .getPageUrls = DummySource.getPageUrlsBridge,
            .canHandle = DummySource.canHandleBridge,
        },
    };

    try reg.register(src1_ms);
    try reg.register(src2_ms);

    try testing.expectEqual(@as(usize, 2), reg.count());
    try testing.expect(reg.has("mangadex"));
    try testing.expect(reg.has("tmo_scraper"));
    try testing.expect(!reg.has("unknown_source"));

    const resolved = reg.get("mangadex");
    try testing.expect(resolved != null);
    try testing.expectEqualStrings("mangadex", resolved.?.getSourceId());

    const resolved2 = reg.get("tmo_scraper");
    try testing.expect(resolved2 != null);
    try testing.expectEqualStrings("tmo_scraper", resolved2.?.getSourceId());

    // Test findByCanHandle
    const found1 = reg.findByCanHandle("https://mangadex.org/title/123");
    try testing.expect(found1 != null);
    try testing.expectEqualStrings("mangadex", found1.?.getSourceId());

    const found2 = reg.findByCanHandle("https://tmo_scraper.com/read/456");
    try testing.expect(found2 != null);
    try testing.expectEqualStrings("tmo_scraper", found2.?.getSourceId());

    const not_found = reg.findByCanHandle("unknown-link");
    try testing.expect(not_found == null);
}
