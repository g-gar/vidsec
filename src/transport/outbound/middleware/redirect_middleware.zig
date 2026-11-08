const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const NetMiddleware = contracts.NetMiddleware;
const NextHandler = contracts.NextHandler;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const RedirectRuleConfig = contracts.RedirectRuleConfig;
const Uri = contracts.Uri;

/// Composable interceptor that rewrites outbound URLs matching `RedirectRuleConfig` across target mirror pools.
/// Implements the polymorphic `NetMiddleware` VTable.
pub const RedirectMiddleware = struct {
    comptime {
        NetMiddleware.assertImplements(@This());
    }

    rules: []const RedirectRuleConfig,
    cursors: []usize,

    pub fn createHeap(allocator: Allocator, rules: []const RedirectRuleConfig) !NetMiddleware {
        const self = try allocator.create(RedirectMiddleware);
        errdefer allocator.destroy(self);
        const cursors = try allocator.alloc(usize, rules.len);
        @memset(cursors, 0);
        self.* = .{
            .rules = rules,
            .cursors = cursors,
        };
        return self.netMiddleware();
    }

    pub fn applyRedirects(self: *RedirectMiddleware, allocator: Allocator, raw_url: []const u8) ![]const u8 {
        for (self.rules, 0..) |rule, idx| {
            if (rule.to.len == 0) continue;
            const prefix = if (std.mem.endsWith(u8, rule.from, "*"))
                rule.from[0 .. rule.from.len - 1]
            else
                rule.from;

            if (std.mem.startsWith(u8, raw_url, prefix)) {
                const suffix = raw_url[prefix.len..];
                const chosen_target = if (rule.strategy == .failover)
                    rule.to[0]
                else blk: {
                    const c = self.cursors[idx] % rule.to.len;
                    self.cursors[idx] = (c + 1) % rule.to.len;
                    break :blk rule.to[c];
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

    pub fn intercept(self: *RedirectMiddleware, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
        const rewritten = self.applyRedirects(exchange.allocator, exchange.effective_url) catch return error.OutOfMemory;
        if (!std.mem.eql(u8, rewritten, exchange.effective_url)) {
            exchange.effective_url = rewritten;
            exchange.uri = Uri.parse(rewritten) orelse return error.InvalidUri;
        }
        return try next_handler.next(exchange);
    }

    pub fn netMiddleware(self: *RedirectMiddleware) NetMiddleware {
        const Trampoline = struct {
            fn doIntercept(ctx: *anyopaque, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
                const s: *RedirectMiddleware = @ptrCast(@alignCast(ctx));
                return try s.intercept(exchange, next_handler);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *RedirectMiddleware = @ptrCast(@alignCast(ctx));
                allocator.free(s.cursors);
                allocator.destroy(s);
            }

            const vtable = NetMiddleware.VTable{
                .intercept = &doIntercept,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
