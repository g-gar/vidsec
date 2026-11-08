const std = @import("std");
pub const matcher = @import("matcher.zig");
pub const anti_ssrf = @import("anti_ssrf.zig");
pub const acl_rules = @import("acl_rules.zig");
pub const tls_policy = @import("tls_policy.zig");
pub const composite_policy = @import("composite_policy.zig");

pub const matchGlob = matcher.matchGlob;
pub const matchResource = matcher.matchResource;
pub const AntiSsrfPolicy = anti_ssrf.AntiSsrfPolicy;
pub const AllowListAclPolicy = acl_rules.AllowListAclPolicy;
pub const TlsSecurityPolicy = tls_policy.TlsSecurityPolicy;
pub const CompositePolicy = composite_policy.CompositePolicy;

test "NetworkPolicyRule: AntiSsrfPolicy granular loopback, link-local, and RFC1918 checks" {
    const testing = std.testing;
    const contracts = @import("../../contracts/mod.zig");

    const ssrf = AntiSsrfPolicy{
        .block_private_ips = true,
        .block_loopback = true,
        .block_link_local = true,
    };
    try testing.expectEqual(contracts.PolicyVerdict.denied_ssrf_loopback, ssrf.classifyHostOrIp("127.0.0.1"));
    try testing.expectEqual(contracts.PolicyVerdict.denied_ssrf_loopback, ssrf.classifyHostOrIp("localhost"));
    try testing.expectEqual(contracts.PolicyVerdict.denied_ssrf_link_local, ssrf.classifyHostOrIp("169.254.169.254"));
    try testing.expectEqual(contracts.PolicyVerdict.denied_ssrf_private_ip, ssrf.classifyHostOrIp("10.24.0.5"));
    try testing.expectEqual(contracts.PolicyVerdict.allowed, ssrf.classifyHostOrIp("104.18.40.10"));
}
