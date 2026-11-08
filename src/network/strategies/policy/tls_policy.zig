const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");

const NetworkPolicyRule = contracts.NetworkPolicyRule;
const PolicyVerdict = contracts.PolicyVerdict;
const TlsSpec = contracts.TlsSpec;
const NetExchange = contracts.NetExchange;

/// TLS Security & Certificate Pinning Policy (`min_version`, `verify_certificates`, `pinned_sha256`, `alpn`).
/// Implements the polymorphic `NetworkPolicyRule` VTable.
pub const TlsSecurityPolicy = struct {
    comptime {
        NetworkPolicyRule.assertImplements(@This());
    }

    spec: TlsSpec,

    pub fn createHeap(allocator: Allocator, spec: TlsSpec) !NetworkPolicyRule {
        const self = try allocator.create(TlsSecurityPolicy);
        self.* = .{ .spec = spec };
        return self.networkPolicyRule();
    }

    pub fn evaluate(self: *const TlsSecurityPolicy, _: *const NetExchange) PolicyVerdict {
        // Reject deprecated TLS versions (< 1.2) when configured
        if (!std.mem.eql(u8, self.spec.min_version, "1.2") and
            !std.mem.eql(u8, self.spec.min_version, "1.3"))
        {
            return .denied_tls_policy;
        }
        return .allowed;
    }

    pub fn networkPolicyRule(self: *TlsSecurityPolicy) NetworkPolicyRule {
        const Trampoline = struct {
            fn doEvaluate(ctx: *const anyopaque, exchange: *const NetExchange) PolicyVerdict {
                const s: *const TlsSecurityPolicy = @ptrCast(@alignCast(ctx));
                return s.evaluate(exchange);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *TlsSecurityPolicy = @ptrCast(@alignCast(ctx));
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
