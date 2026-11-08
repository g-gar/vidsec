const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");
const DnsResolver = contracts.DnsResolver;
const DnsResolution = contracts.DnsResolution;
const DnsConfig = contracts.DnsConfig;

/// Scoped in-memory DNS Resolver with static overrides, TTL clamping, and `stale-while-revalidate`.
/// Implements the polymorphic `DnsResolver` VTable.
pub const ScopedMemoryDnsResolver = struct {
    comptime {
        DnsResolver.assertImplements(@This());
    }

    pub const CacheEntry = struct {
        ip_address: []const u8,
        expires_at_ms: u64,
        stale_until_ms: u64,
    };

    allocator: Allocator,
    spec: DnsConfig,
    entries: std.StringHashMapUnmanaged(CacheEntry) = .empty,
    hit_count: usize = 0,
    miss_count: usize = 0,

    pub fn init(allocator: Allocator, spec: DnsConfig) ScopedMemoryDnsResolver {
        return .{
            .allocator = allocator,
            .spec = spec,
        };
    }

    pub fn createHeap(allocator: Allocator, spec: DnsConfig) !DnsResolver {
        const self = try allocator.create(ScopedMemoryDnsResolver);
        self.* = ScopedMemoryDnsResolver.init(allocator, spec);
        return self.dnsResolver();
    }

    pub fn deinitInternal(self: *ScopedMemoryDnsResolver) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.ip_address);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn resolve(self: *ScopedMemoryDnsResolver, host: []const u8, now_ms: u64) DnsResolution {
        for (self.spec.overrides) |ov| {
            if (std.ascii.eqlIgnoreCase(ov.key, host)) {
                self.hit_count += 1;
                return .{ .ip_address = ov.value, .source = .static_override };
            }
        }

        if (self.entries.get(host)) |entry| {
            if (now_ms <= entry.expires_at_ms) {
                self.hit_count += 1;
                return .{ .ip_address = entry.ip_address, .source = .cache_fresh };
            }
            if (now_ms <= entry.stale_until_ms) {
                self.hit_count += 1;
                return .{ .ip_address = entry.ip_address, .source = .cache_stale_revalidating };
            }
        }

        self.miss_count += 1;
        return .{ .ip_address = null, .source = .miss };
    }

    pub fn put(self: *ScopedMemoryDnsResolver, host: []const u8, ip: []const u8, raw_ttl_sec: u64, now_ms: u64) !void {
        const clamped_ttl = std.math.clamp(raw_ttl_sec, self.spec.min_ttl_sec, self.spec.max_ttl_sec);
        const expires_ms = now_ms + clamped_ttl * 1000;
        const stale_ms = expires_ms + self.spec.stale_while_revalidate_sec * 1000;

        if (self.entries.getPtr(host)) |existing| {
            const new_ip = try self.allocator.dupe(u8, ip);
            self.allocator.free(existing.ip_address);
            existing.* = .{
                .ip_address = new_ip,
                .expires_at_ms = expires_ms,
                .stale_until_ms = stale_ms,
            };
            return;
        }

        const owned_host = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(owned_host);
        const owned_ip = try self.allocator.dupe(u8, ip);
        errdefer self.allocator.free(owned_ip);

        try self.entries.put(self.allocator, owned_host, .{
            .ip_address = owned_ip,
            .expires_at_ms = expires_ms,
            .stale_until_ms = stale_ms,
        });
    }

    pub fn dnsResolver(self: *ScopedMemoryDnsResolver) DnsResolver {
        const Trampoline = struct {
            fn doResolve(ctx: *anyopaque, host: []const u8, now_ms: u64) DnsResolution {
                const s: *ScopedMemoryDnsResolver = @ptrCast(@alignCast(ctx));
                return s.resolve(host, now_ms);
            }

            fn doPut(ctx: *anyopaque, host: []const u8, ip: []const u8, raw_ttl_sec: u64, now_ms: u64) anyerror!void {
                const s: *ScopedMemoryDnsResolver = @ptrCast(@alignCast(ctx));
                try s.put(host, ip, raw_ttl_sec, now_ms);
            }

            fn doHits(ctx: *const anyopaque) usize {
                const s: *const ScopedMemoryDnsResolver = @ptrCast(@alignCast(ctx));
                return s.hit_count;
            }

            fn doMisses(ctx: *const anyopaque) usize {
                const s: *const ScopedMemoryDnsResolver = @ptrCast(@alignCast(ctx));
                return s.miss_count;
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *ScopedMemoryDnsResolver = @ptrCast(@alignCast(ctx));
                s.deinitInternal();
                allocator.destroy(s);
            }

            const vtable = DnsResolver.VTable{
                .resolve = &doResolve,
                .put = &doPut,
                .hits = &doHits,
                .misses = &doMisses,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
