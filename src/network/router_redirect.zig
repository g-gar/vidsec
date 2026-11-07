const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/ast.zig");
const policy_engine = @import("policy_engine.zig");

/// Rewrites outbound URLs matching `redirects:` prefix rules across target mirror pools (`round_robin` or `failover`).
pub const RedirectRouter = struct {
    rules: []const ast.RedirectRuleSpec,
    cursors: []usize,

    pub fn init(allocator: Allocator, rules: []const ast.RedirectRuleSpec) !RedirectRouter {
        const cursors = try allocator.alloc(usize, rules.len);
        @memset(cursors, 0);
        return .{
            .rules = rules,
            .cursors = cursors,
        };
    }

    pub fn deinit(self: *RedirectRouter, allocator: Allocator) void {
        allocator.free(self.cursors);
    }

    pub fn applyRedirects(self: *RedirectRouter, allocator: Allocator, raw_url: []const u8) ![]const u8 {
        for (self.rules, 0..) |rule, idx| {
            if (rule.to.len == 0) continue;
            const prefix = if (std.mem.endsWith(u8, rule.from, "*"))
                rule.from[0 .. rule.from.len - 1]
            else
                rule.from;

            if (std.mem.startsWith(u8, raw_url, prefix)) {
                const suffix = raw_url[prefix.len..];
                const chosen_target = switch (rule.strategy) {
                    .failover => rule.to[0],
                    else => blk: {
                        const c = self.cursors[idx] % rule.to.len;
                        self.cursors[idx] = (c + 1) % rule.to.len;
                        break :blk rule.to[c];
                    },
                };
                if (std.mem.endsWith(u8, chosen_target, "$1")) {
                    const base_target = chosen_target[0 .. chosen_target.len - 2];
                    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_target, suffix });
                }
                return try std.fmt.allocPrint(allocator, "{s}{s}", .{ chosen_target, suffix });
            }
        }
        return raw_url;
    }
};

/// Matches destination hostnames against `routes:` split-tunnel rules.
pub fn matchSplitRoute(routes: []const ast.RouteRuleSpec, dst_host: []const u8) ?ast.RouteRuleSpec {
    for (routes) |route| {
        if (policy_engine.matchGlob(route.match_host, dst_host)) {
            return route;
        }
    }
    return null;
}

test "router_redirect: URL mirror rewriting and split-tunnel host matching" {
    const testing = std.testing;
    const redirects = [_]ast.RedirectRuleSpec{
        .{
            .from = "https://uploads.mangadex.org",
            .to = &.{
                "https://mirror-a.cdn.internal/uploads",
                "https://mirror-b.cdn.internal/uploads",
            },
            .strategy = .round_robin,
        },
    };

    var red = try RedirectRouter.init(testing.allocator, &redirects);
    defer red.deinit(testing.allocator);

    const r1 = try red.applyRedirects(testing.allocator, "https://uploads.mangadex.org/covers/123.jpg");
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("https://mirror-a.cdn.internal/uploads/covers/123.jpg", r1);

    const r2 = try red.applyRedirects(testing.allocator, "https://uploads.mangadex.org/covers/456.jpg");
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("https://mirror-b.cdn.internal/uploads/covers/456.jpg", r2);

    const routes = [_]ast.RouteRuleSpec{
        .{
            .match_host = "*.mangadex.network",
            .proxy_strategy = .least_latency,
        },
    };
    const matched = matchSplitRoute(&routes, "s2.mangadex.network").?;
    try testing.expectEqual(ast.ProxyStrategy.least_latency, matched.proxy_strategy.?);
}
