const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../../contracts/mod.zig");
const NetworkPolicyRule = contracts.NetworkPolicyRule;
const PolicyVerdict = contracts.PolicyVerdict;
const NetExchange = contracts.NetExchange;
const NetworkPolicySpec = contracts.NetworkPolicySpec;

/// Pre-Connect Anti-SSRF Security Policy (`block_private_ips`, `block_loopback`, `block_link_local`).
/// Evaluates both the literal URI hostname and the pre-resolved DNS IP (`exchange.resolved_ip`)
/// to prevent DNS Rebinding and cloud metadata exfiltration (`169.254.169.254`).
/// Implements the polymorphic `NetworkPolicyRule` VTable.
pub const AntiSsrfPolicy = struct {
    comptime {
        NetworkPolicyRule.assertImplements(@This());
    }

    block_private_ips: bool = true,
    block_loopback: bool = true,
    block_link_local: bool = true,

    pub fn fromSpec(spec: NetworkPolicySpec) AntiSsrfPolicy {
        const master = spec.block_private_ranges;
        return .{
            .block_private_ips = master and spec.block_private_ips,
            .block_loopback = master and spec.block_loopback,
            .block_link_local = master and spec.block_link_local,
        };
    }

    pub fn createHeap(allocator: Allocator, spec: NetworkPolicySpec) !NetworkPolicyRule {
        const self = try allocator.create(AntiSsrfPolicy);
        self.* = AntiSsrfPolicy.fromSpec(spec);
        return self.networkPolicyRule();
    }

    pub fn evaluate(self: *const AntiSsrfPolicy, exchange: *const NetExchange) PolicyVerdict {
        const host_verdict = self.classifyHostOrIp(exchange.uri.host);
        if (host_verdict != .allowed) return host_verdict;

        if (exchange.resolved_ip) |ip| {
            const ip_verdict = self.classifyHostOrIp(ip);
            if (ip_verdict != .allowed) return ip_verdict;
        }

        return .allowed;
    }

    pub fn classifyHostOrIp(self: *const AntiSsrfPolicy, host_or_ip: []const u8) PolicyVerdict {
        const trimmed = std.mem.trim(u8, host_or_ip, "[] \t");

        // 1. Loopback hostnames & IPv6 loopback (`localhost`, `*.localhost`, `::1`, `::`, `0.0.0.0`)
        if (std.ascii.eqlIgnoreCase(trimmed, "localhost") or
            std.ascii.endsWithIgnoreCase(trimmed, ".localhost") or
            std.mem.eql(u8, trimmed, "::1") or
            std.mem.eql(u8, trimmed, "::") or
            std.mem.eql(u8, trimmed, "0.0.0.0"))
        {
            if (self.block_loopback) return .denied_ssrf_loopback;
            return .allowed;
        }

        // 2. IPv6 ULA (`fc00::/7`) and Link-Local (`fe80::/10`)
        if (std.mem.indexOfScalar(u8, trimmed, ':') != null) {
            if (trimmed.len >= 2) {
                if (std.ascii.startsWithIgnoreCase(trimmed, "fe80")) {
                    if (self.block_link_local) return .denied_ssrf_link_local;
                }
                if (std.ascii.startsWithIgnoreCase(trimmed, "fc") or
                    std.ascii.startsWithIgnoreCase(trimmed, "fd"))
                {
                    if (self.block_private_ips) return .denied_ssrf_private_ip;
                }
            }
            return .allowed;
        }

        // 3. IPv4 dotted quad `a.b.c.d`
        var octets: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, trimmed, '.');
        var idx: usize = 0;
        while (it.next()) |part| : (idx += 1) {
            if (idx >= 4) return .allowed;
            octets[idx] = std.fmt.parseInt(u8, part, 10) catch return .allowed;
        }
        if (idx != 4) return .allowed;

        const a = octets[0];
        const b = octets[1];

        if (a == 127 or a == 0) {
            if (self.block_loopback) return .denied_ssrf_loopback;
        }
        if (a == 169 and b == 254) {
            // Link-local (`169.254.0.0/16`) & Cloud IMDSv1/v2 (`169.254.169.254`)
            if (self.block_link_local) return .denied_ssrf_link_local;
        }
        if (a == 10 or
            (a == 172 and (b >= 16 and b <= 31)) or
            (a == 192 and b == 168) or
            (a == 100 and (b >= 64 and b <= 127)) or
            a >= 224)
        {
            if (self.block_private_ips) return .denied_ssrf_private_ip;
        }

        return .allowed;
    }

    pub fn networkPolicyRule(self: *AntiSsrfPolicy) NetworkPolicyRule {
        const Trampoline = struct {
            fn doEvaluate(ctx: *const anyopaque, exchange: *const NetExchange) PolicyVerdict {
                const s: *const AntiSsrfPolicy = @ptrCast(@alignCast(ctx));
                return s.evaluate(exchange);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *AntiSsrfPolicy = @ptrCast(@alignCast(ctx));
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
