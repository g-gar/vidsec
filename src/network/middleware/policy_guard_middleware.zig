const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const NetMiddleware = contracts.NetMiddleware;
const NextHandler = contracts.NextHandler;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const NetworkPolicyRule = contracts.NetworkPolicyRule;

/// Composable Policy Guard interceptor that delegates evaluation to an injected `NetworkPolicyRule` VTable
/// (`AntiSsrfPolicy`, `AllowListAclPolicy`, `TlsSecurityPolicy`, or `CompositePolicy`).
pub const PolicyGuardMiddleware = struct {
    comptime {
        NetMiddleware.assertImplements(@This());
    }

    rule: NetworkPolicyRule,

    pub fn createHeap(allocator: Allocator, rule: NetworkPolicyRule) !NetMiddleware {
        const self = try allocator.create(PolicyGuardMiddleware);
        self.* = .{ .rule = rule };
        return self.netMiddleware();
    }

    pub fn intercept(self: *PolicyGuardMiddleware, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
        if (self.rule.evaluate(exchange) != .allowed) {
            exchange.metrics.requests_blocked += 1;
            return error.NetworkPolicyDenied;
        }
        return try next_handler.next(exchange);
    }

    pub fn netMiddleware(self: *PolicyGuardMiddleware) NetMiddleware {
        const Trampoline = struct {
            fn doIntercept(ctx: *anyopaque, exchange: *NetExchange, next_handler: NextHandler) NetError!NetResult {
                const s: *PolicyGuardMiddleware = @ptrCast(@alignCast(ctx));
                return try s.intercept(exchange, next_handler);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *PolicyGuardMiddleware = @ptrCast(@alignCast(ctx));
                s.rule.deinit(allocator);
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
