const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");
const matcher = @import("matcher.zig");

const NetworkPolicyRule = contracts.NetworkPolicyRule;
const PolicyVerdict = contracts.PolicyVerdict;
const PolicyDefaultAction = contracts.PolicyDefaultAction;
const AllowRuleSpec = contracts.AllowRuleSpec;
const NetworkPolicySpec = contracts.NetworkPolicySpec;
const NetExchange = contracts.NetExchange;
const Uri = contracts.Uri;

/// Combinatorial L4/L7 ACL Policy (`default_action: deny | allow` + `allow_rules` on `schemes`, `hosts`, `ports`, `operations`, `resources`).
/// Implements the polymorphic `NetworkPolicyRule` VTable.
pub const AllowListAclPolicy = struct {
    comptime {
        NetworkPolicyRule.assertImplements(@This());
    }

    default_action: PolicyDefaultAction = .deny,
    allow_rules: []const AllowRuleSpec = &.{},

    pub fn createHeap(allocator: Allocator, spec: NetworkPolicySpec) !NetworkPolicyRule {
        const self = try allocator.create(AllowListAclPolicy);
        self.* = .{
            .default_action = spec.default_action,
            .allow_rules = spec.allow_rules,
        };
        return self.networkPolicyRule();
    }

    pub fn evaluate(self: *const AllowListAclPolicy, exchange: *const NetExchange) PolicyVerdict {
        if (self.allow_rules.len == 0) {
            return .allowed;
        }

        for (self.allow_rules) |rule| {
            if (matchesRule(rule, exchange.uri, exchange.operation)) {
                return .allowed;
            }
        }

        return if (self.default_action == .allow) .allowed else .denied_acl_mismatch;
    }

    pub fn matchesRule(rule: AllowRuleSpec, uri: Uri, operation: []const u8) bool {
        if (rule.schemes.len > 0) {
            var scheme_ok = false;
            for (rule.schemes) |sc| {
                if (std.ascii.eqlIgnoreCase(sc, uri.scheme)) {
                    scheme_ok = true;
                    break;
                }
            }
            if (!scheme_ok) return false;
        }

        if (rule.hosts.len > 0) {
            var host_ok = false;
            for (rule.hosts) |h_pat| {
                if (matcher.matchGlob(h_pat, uri.host)) {
                    host_ok = true;
                    break;
                }
            }
            if (!host_ok) return false;
        }

        if (rule.ports.len > 0) {
            var port_ok = false;
            for (rule.ports) |pr| {
                if (pr.contains(uri.port)) {
                    port_ok = true;
                    break;
                }
            }
            if (!port_ok) return false;
        }

        if (rule.operations.len > 0) {
            var op_ok = false;
            for (rule.operations) |op| {
                if (std.mem.eql(u8, op, "*") or std.ascii.eqlIgnoreCase(op, operation)) {
                    op_ok = true;
                    break;
                }
            }
            if (!op_ok) return false;
        }

        if (rule.resources.len > 0) {
            var res_ok = false;
            for (rule.resources) |res_pat| {
                if (matcher.matchResource(res_pat, uri.resource)) {
                    res_ok = true;
                    break;
                }
            }
            if (!res_ok) return false;
        }

        return true;
    }

    pub fn networkPolicyRule(self: *AllowListAclPolicy) NetworkPolicyRule {
        const Trampoline = struct {
            fn doEvaluate(ctx: *const anyopaque, exchange: *const NetExchange) PolicyVerdict {
                const s: *const AllowListAclPolicy = @ptrCast(@alignCast(ctx));
                return s.evaluate(exchange);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *AllowListAclPolicy = @ptrCast(@alignCast(ctx));
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
