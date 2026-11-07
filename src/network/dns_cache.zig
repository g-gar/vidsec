const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/ast.zig");

pub const DnsCacheEntry = struct {
    ip_address: []const u8,
    expires_at_ms: u64,
    stale_until_ms: u64,
};

pub const DnsLookupStatus = enum {
    static_override,
    cache_fresh,
    cache_stale_revalidating,
    cache_miss,
};

pub const DnsLookupResult = struct {
    ip_address: ?[]const u8,
    status: DnsLookupStatus,
};

/// Scoped Non-Blocking DNS Cache with Static Overrides, TTL Enforcement, and `stale-while-revalidate`.
pub const DnsCache = struct {
    arena: std.heap.ArenaAllocator,
    spec: ast.DnsSpec,
    entries: std.StringHashMapUnmanaged(DnsCacheEntry) = .empty,
    hits: usize = 0,
    misses: usize = 0,

    pub fn init(backing_allocator: Allocator, spec: ast.DnsSpec) DnsCache {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .spec = spec,
        };
    }

    pub fn deinit(self: *DnsCache) void {
        self.arena.deinit();
    }

    pub fn resolve(self: *DnsCache, host: []const u8, now_ms: u64) DnsLookupResult {
        // 1. Check static adapter overrides (`dns.overrides`)
        for (self.spec.overrides) |ov| {
            if (std.ascii.eqlIgnoreCase(ov.key, host)) {
                self.hits += 1;
                return .{
                    .ip_address = ov.value,
                    .status = .static_override,
                };
            }
        }

        // 2. Check scoped reactive TTL cache
        if (self.entries.get(host)) |entry| {
            if (now_ms <= entry.expires_at_ms) {
                self.hits += 1;
                return .{
                    .ip_address = entry.ip_address,
                    .status = .cache_fresh,
                };
            }
            if (now_ms <= entry.stale_until_ms) {
                self.hits += 1;
                return .{
                    .ip_address = entry.ip_address,
                    .status = .cache_stale_revalidating,
                };
            }
        }

        self.misses += 1;
        return .{
            .ip_address = null,
            .status = .cache_miss,
        };
    }

    pub fn put(self: *DnsCache, host: []const u8, ip_address: []const u8, ttl_sec: u64, now_ms: u64) !void {
        const alloc = self.arena.allocator();
        const clamped_ttl = std.math.clamp(ttl_sec, self.spec.min_ttl_sec, self.spec.max_ttl_sec);
        const expires_ms = now_ms + (clamped_ttl * 1000);
        const stale_ms = expires_ms + (self.spec.stale_while_revalidate_sec * 1000);

        const host_copy = try alloc.dupe(u8, host);
        const ip_copy = try alloc.dupe(u8, ip_address);
        try self.entries.put(alloc, host_copy, .{
            .ip_address = ip_copy,
            .expires_at_ms = expires_ms,
            .stale_until_ms = stale_ms,
        });
    }
};

test "dns_cache: static overrides, TTL clamping, and stale-while-revalidate" {
    const testing = std.testing;
    const overrides = [_]ast.KeyValueParam{
        .{ .key = "api.mangadex.local", .value = "127.0.0.1" },
    };

    var cache = DnsCache.init(testing.allocator, .{
        .min_ttl_sec = 10,
        .max_ttl_sec = 60,
        .stale_while_revalidate_sec = 5,
        .overrides = &overrides,
    });
    defer cache.deinit();

    // 1. Static override
    const r_ov = cache.resolve("api.mangadex.local", 1000);
    try testing.expectEqual(DnsLookupStatus.static_override, r_ov.status);
    try testing.expectEqualStrings("127.0.0.1", r_ov.ip_address.?);

    // 2. Cache miss -> populate with 2s TTL (clamped to min_ttl_sec = 10s -> 10,000ms)
    const r_miss = cache.resolve("api.mangadex.org", 1000);
    try testing.expectEqual(DnsLookupStatus.cache_miss, r_miss.status);

    try cache.put("api.mangadex.org", "104.18.40.10", 2, 1000);

    // Fresh at t=8000ms (expires at 11000ms)
    const r_fresh = cache.resolve("api.mangadex.org", 8000);
    try testing.expectEqual(DnsLookupStatus.cache_fresh, r_fresh.status);
    try testing.expectEqualStrings("104.18.40.10", r_fresh.ip_address.?);

    // Stale-while-revalidate at t=13000ms (between 11000ms and 16000ms)
    const r_stale = cache.resolve("api.mangadex.org", 13000);
    try testing.expectEqual(DnsLookupStatus.cache_stale_revalidating, r_stale.status);
    try testing.expectEqualStrings("104.18.40.10", r_stale.ip_address.?);

    // Expired after 16000ms
    const r_exp = cache.resolve("api.mangadex.org", 17000);
    try testing.expectEqual(DnsLookupStatus.cache_miss, r_exp.status);
}
