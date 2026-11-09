const std = @import("std");
const root = @import("root.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const cfg = try root.AppConfig.load(allocator, ".env");
    defer {
        if (!std.mem.eql(u8, cfg.api_url, "https://api.mangadex.org")) allocator.free(cfg.api_url);
        if (!std.mem.eql(u8, cfg.auth_url, "https://auth.mangadex.org/realms/mangadex/protocol/openid-connect/token")) allocator.free(cfg.auth_url);
    }

    std.debug.print("MangaDex Application Initialized (API: {s})\n", .{cfg.api_url});
}
