const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DnsSource = enum {
    static_override,
    cache_fresh,
    cache_stale_revalidating,
    miss,
};

pub const DnsResolution = struct {
    ip_address: ?[]const u8,
    source: DnsSource,
};

/// Polymorphic VTable interface for DNS Resolution engines (Scoped Memory Cache, Static Hosts, DoH/UDP Resolver).
pub const DnsResolver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resolve: *const fn (ctx: *anyopaque, host: []const u8, now_ms: u64) DnsResolution,
        put: *const fn (ctx: *anyopaque, host: []const u8, ip: []const u8, raw_ttl_sec: u64, now_ms: u64) anyerror!void,
        hits: *const fn (ctx: *const anyopaque) usize,
        misses: *const fn (ctx: *const anyopaque) usize,
        deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub fn resolve(self: DnsResolver, host: []const u8, now_ms: u64) DnsResolution {
        return self.vtable.resolve(self.ptr, host, now_ms);
    }

    pub fn put(self: DnsResolver, host: []const u8, ip: []const u8, raw_ttl_sec: u64, now_ms: u64) !void {
        try self.vtable.put(self.ptr, host, ip, raw_ttl_sec, now_ms);
    }

    pub fn hits(self: DnsResolver) usize {
        return self.vtable.hits(self.ptr);
    }

    pub fn misses(self: DnsResolver) usize {
        return self.vtable.misses(self.ptr);
    }

    pub fn deinit(self: DnsResolver, allocator: Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "dnsResolver")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn dnsResolver(*" ++ @typeName(T) ++ ") DnsResolver'");
            }
        }
    }
};
