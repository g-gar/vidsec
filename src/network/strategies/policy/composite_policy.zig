const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");
const AntiSsrfPolicy = @import("anti_ssrf.zig").AntiSsrfPolicy;
const AllowListAclPolicy = @import("acl_rules.zig").AllowListAclPolicy;
const TlsSecurityPolicy = @import("tls_policy.zig").TlsSecurityPolicy;

const NetworkPolicyRule = contracts.NetworkPolicyRule;
const PolicyVerdict = contracts.PolicyVerdict;
const NetExchange = contracts.NetExchange;
const NetworkSpec = contracts.NetworkSpec;

/// Short-circuiting chain of polymorphic `NetworkPolicyRule` instances (`AntiSsrfPolicy` + `AllowListAclPolicy` + `TlsSecurityPolicy`).
/// Implements the `NetworkPolicyRule` VTable.
pub const CompositePolicy = struct {
    comptime {
        NetworkPolicyRule.assertImplements(@This());
    }

    rules: std.ArrayListUnmanaged(NetworkPolicyRule) = .empty,

    pub fn createFromSpec(allocator: Allocator, spec: NetworkSpec) !NetworkPolicyRule {
        const self = try allocator.create(CompositePolicy);
        self.* = .{};
        errdefer {
            for (self.rules.items) |r| r.deinit(allocator);
            self.rules.deinit(allocator);
            allocator.destroy(self);
        }

        try self.rules.append(allocator, try AntiSsrfPolicy.createHeap(allocator, spec.policy));
        try self.rules.append(allocator, try AllowListAclPolicy.createHeap(allocator, spec.policy));
        try self.rules.append(allocator, try TlsSecurityPolicy.createHeap(allocator, spec.tls));

        return self.networkPolicyRule();
    }

    pub fn evaluate(self: *const CompositePolicy, exchange: *const NetExchange) PolicyVerdict {
        for (self.rules.items) |rule| {
            const verdict = rule.evaluate(exchange);
            if (verdict != .allowed) return verdict;
        }
        return .allowed;
    }

    pub fn networkPolicyRule(self: *CompositePolicy) NetworkPolicyRule {
        const Trampoline = struct {
            fn doEvaluate(ctx: *const anyopaque, exchange: *const NetExchange) PolicyVerdict {
                const s: *const CompositePolicy = @ptrCast(@alignCast(ctx));
                return s.evaluate(exchange);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *CompositePolicy = @ptrCast(@alignCast(ctx));
                for (s.rules.items) |r| {
                    r.deinit(allocator);
                }
                s.rules.deinit(allocator);
                allocator.destroy(s);
            }

            const vtable = NetworkPolicyRule.VTable{
                .evaluate = &doEvaluate,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
