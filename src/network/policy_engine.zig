const std = @import("std");
const ast = @import("../ast/ast.zig");

pub const ParsedUri = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    resource: []const u8,

    pub fn parse(raw_url: []const u8) ?ParsedUri {
        const trimmed = std.mem.trim(u8, raw_url, " \t\r\n");
        const scheme_sep = std.mem.indexOf(u8, trimmed, "://") orelse return null;
        if (scheme_sep == 0) return null;

        const scheme = trimmed[0..scheme_sep];
        const rest = trimmed[scheme_sep + 3 ..];
        if (rest.len == 0) return null;

        const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..slash_idx];
        const resource = if (slash_idx < rest.len) rest[slash_idx..] else "/";

        var host = authority;
        var port: u16 = defaultPortForScheme(scheme);

        // Handle IPv6 bracketed host `[::1]:8080` vs standard `host:port`
        if (std.mem.startsWith(u8, authority, "[")) {
            if (std.mem.indexOfScalar(u8, authority, ']')) |close_bracket| {
                host = authority[1..close_bracket];
                if (close_bracket + 1 < authority.len and authority[close_bracket + 1] == ':') {
                    port = std.fmt.parseInt(u16, authority[close_bracket + 2 ..], 10) catch return null;
                }
            } else return null;
        } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon_idx| {
            host = authority[0..colon_idx];
            port = std.fmt.parseInt(u16, authority[colon_idx + 1 ..], 10) catch return null;
        }

        if (host.len == 0) return null;
        return .{
            .scheme = scheme,
            .host = host,
            .port = port,
            .resource = resource,
        };
    }

    pub fn defaultPortForScheme(scheme: []const u8) u16 {
        if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "ws")) return 80;
        if (std.ascii.eqlIgnoreCase(scheme, "https") or
            std.ascii.eqlIgnoreCase(scheme, "wss") or
            std.ascii.eqlIgnoreCase(scheme, "grpcs") or
            std.ascii.eqlIgnoreCase(scheme, "rtmps") or
            std.ascii.eqlIgnoreCase(scheme, "tls") or
            std.ascii.eqlIgnoreCase(scheme, "quic")) return 443;
        if (std.ascii.eqlIgnoreCase(scheme, "grpc")) return 50051;
        if (std.ascii.eqlIgnoreCase(scheme, "rtmp")) return 1935;
        if (std.ascii.eqlIgnoreCase(scheme, "rtsp")) return 554;
        if (std.ascii.eqlIgnoreCase(scheme, "amqp")) return 5672;
        if (std.ascii.eqlIgnoreCase(scheme, "amqps")) return 5671;
        return 0;
    }
};

/// Glob pattern matcher supporting leading/trailing/interior `*` wildcards
/// (e.g. `*.mangadex.network`, `/manga/*`, `/flowdata.v2.Coordinator/*`).
pub fn matchGlob(pattern: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;

    if (std.mem.indexOfScalar(u8, pattern, '*')) |star_idx| {
        const prefix = pattern[0..star_idx];
        const suffix = pattern[star_idx + 1 ..];

        // Special case for subdomain glob `*.example.com`
        if (std.mem.eql(u8, prefix, "") and std.mem.startsWith(u8, suffix, ".")) {
            if (std.ascii.eqlIgnoreCase(value, suffix[1..])) return false; // require subdomain
            if (value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix)) {
                return true;
            }
            return false;
        }

        if (value.len < prefix.len + suffix.len) return false;
        if (!std.ascii.startsWithIgnoreCase(value, prefix)) return false;
        if (!std.ascii.endsWithIgnoreCase(value, suffix)) return false;
        return true;
    }

    return std.ascii.eqlIgnoreCase(pattern, value);
}

/// Matches a URI resource path against either an exact prefix (`/manga`) or glob (`/manga/*`).
pub fn matchResource(pattern: []const u8, resource_path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') != null) {
        // Strip query string when matching path glob if pattern doesn't include '?'
        const clean_path = if (std.mem.indexOfScalar(u8, pattern, '?') == null)
            (if (std.mem.indexOfScalar(u8, resource_path, '?')) |q| resource_path[0..q] else resource_path)
        else
            resource_path;

        // Also allow `/manga/*` to match `/manga` exact root
        if (std.mem.endsWith(u8, pattern, "/*")) {
            const base = pattern[0 .. pattern.len - 2];
            if (std.mem.eql(u8, clean_path, base)) return true;
        }
        return matchGlob(pattern, clean_path);
    }
    return std.mem.startsWith(u8, resource_path, pattern);
}

/// Pre-Connect Anti-SSRF Validator: detects loopback, RFC1918 private networks,
/// link-local (`169.254.0.0/16`), cloud metadata (`169.254.169.254`), and IPv6 local ranges.
pub fn isPrivateOrReservedHostOrIp(host_or_ip: []const u8) bool {
    const trimmed = std.mem.trim(u8, host_or_ip, "[] \t");
    if (std.ascii.eqlIgnoreCase(trimmed, "localhost") or
        std.ascii.endsWithIgnoreCase(trimmed, ".localhost") or
        std.mem.eql(u8, trimmed, "::1") or
        std.mem.eql(u8, trimmed, "::") or
        std.mem.eql(u8, trimmed, "0.0.0.0"))
    {
        return true;
    }

    // IPv6 ULA (`fc00::/7` -> fc.. or fd..) and Link-Local (`fe80::/10`)
    if (std.mem.indexOfScalar(u8, trimmed, ':') != null) {
        if (trimmed.len >= 2) {
            if (std.ascii.startsWithIgnoreCase(trimmed, "fc") or
                std.ascii.startsWithIgnoreCase(trimmed, "fd") or
                std.ascii.startsWithIgnoreCase(trimmed, "fe80"))
            {
                return true;
            }
        }
        return false;
    }

    // Parse IPv4 dotted quad `a.b.c.d`
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, trimmed, '.');
    var idx: usize = 0;
    while (it.next()) |part| : (idx += 1) {
        if (idx >= 4) return false;
        octets[idx] = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    if (idx != 4) return false;

    const a = octets[0];
    const b = octets[1];

    if (a == 0) return true; // 0.0.0.0/8
    if (a == 10) return true; // 10.0.0.0/8 (RFC1918)
    if (a == 127) return true; // 127.0.0.0/8 (Loopback)
    if (a == 169 and b == 254) return true; // 169.254.0.0/16 (Link-local & Cloud Metadata 169.254.169.254)
    if (a == 172 and (b >= 16 and b <= 31)) return true; // 172.16.0.0/12 (RFC1918)
    if (a == 192 and b == 168) return true; // 192.168.0.0/16 (RFC1918)
    if (a == 100 and (b >= 64 and b <= 127)) return true; // 100.64.0.0/10 (CGNAT)
    if (a >= 224) return true; // Multicast & Reserved

    return false;
}

pub const PolicyVerdict = enum {
    allowed,
    denied_driver,
    denied_ssrf_private_ip,
    denied_acl_mismatch,
};

/// Evaluates an outbound request against the adapter's driver and L4/L7 `NetworkPolicySpec`.
pub fn evaluateOutboundPolicy(
    driver: ast.NetworkDriver,
    policy: ast.NetworkPolicySpec,
    uri: ParsedUri,
    operation: []const u8,
    resolved_ip: ?[]const u8,
) PolicyVerdict {
    switch (driver) {
        .none, .ingress_only => return .denied_driver,
        .sinkhole, .egress => {},
    }

    if (policy.block_private_ranges) {
        if (isPrivateOrReservedHostOrIp(uri.host)) return .denied_ssrf_private_ip;
        if (resolved_ip) |ip| {
            if (isPrivateOrReservedHostOrIp(ip)) return .denied_ssrf_private_ip;
        }
    }

    if (policy.allow_rules.len == 0) {
        return .allowed;
    }

    for (policy.allow_rules) |rule| {
        if (matchesRule(rule, uri, operation)) {
            return .allowed;
        }
    }

    return .denied_acl_mismatch;
}

fn matchesRule(rule: ast.AllowRuleSpec, uri: ParsedUri, operation: []const u8) bool {
    // 1. Schemes check
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

    // 2. Hosts check
    if (rule.hosts.len > 0) {
        var host_ok = false;
        for (rule.hosts) |h_pat| {
            if (matchGlob(h_pat, uri.host)) {
                host_ok = true;
                break;
            }
        }
        if (!host_ok) return false;
    }

    // 3. Ports check
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

    // 4. Operations check
    if (rule.operations.len > 0) {
        var op_ok = false;
        for (rule.operations) |op| {
            if (std.ascii.eqlIgnoreCase(op, operation)) {
                op_ok = true;
                break;
            }
        }
        if (!op_ok) return false;
    }

    // 5. Resources check
    if (rule.resources.len > 0) {
        var res_ok = false;
        for (rule.resources) |res_pat| {
            if (matchResource(res_pat, uri.resource)) {
                res_ok = true;
                break;
            }
        }
        if (!res_ok) return false;
    }

    return true;
}

test "policy_engine: URI parsing, multi-protocol ACL matching, and Anti-SSRF validation" {
    const testing = std.testing;

    const uri_md = ParsedUri.parse("https://api.mangadex.org/manga/a96676e5/feed?translatedLanguage[]=es").?;
    try testing.expectEqualStrings("https", uri_md.scheme);
    try testing.expectEqualStrings("api.mangadex.org", uri_md.host);
    try testing.expectEqual(@as(u16, 443), uri_md.port);
    try testing.expectEqualStrings("/manga/a96676e5/feed?translatedLanguage[]=es", uri_md.resource);

    // Anti-SSRF checks
    try testing.expect(isPrivateOrReservedHostOrIp("127.0.0.1"));
    try testing.expect(isPrivateOrReservedHostOrIp("10.0.0.5"));
    try testing.expect(isPrivateOrReservedHostOrIp("169.254.169.254"));
    try testing.expect(isPrivateOrReservedHostOrIp("192.168.1.1"));
    try testing.expect(isPrivateOrReservedHostOrIp("localhost"));
    try testing.expect(!isPrivateOrReservedHostOrIp("api.mangadex.org"));
    try testing.expect(!isPrivateOrReservedHostOrIp("104.18.40.10"));

    // Multi-protocol rule evaluation (HTTPS + gRPC + RTMPS)
    const rules = [_]ast.AllowRuleSpec{
        .{
            .schemes = &.{"https"},
            .hosts = &.{ "api.mangadex.org", "*.mangadex.network" },
            .ports = &.{ast.PortRangeSpec.single(443)},
            .operations = &.{"GET"},
            .resources = &.{ "/manga/*", "/data/*" },
        },
        .{
            .schemes = &.{"rtmps"},
            .hosts = &.{"ingest.stream.example.com"},
            .ports = &.{ast.PortRangeSpec.single(443)},
            .operations = &.{"PUBLISH"},
            .resources = &.{"/live/*"},
        },
    };
    const policy = ast.NetworkPolicySpec{
        .block_private_ranges = true,
        .allow_rules = &rules,
    };

    try testing.expectEqual(PolicyVerdict.allowed, evaluateOutboundPolicy(.egress, policy, uri_md, "GET", "104.18.40.10"));
    try testing.expectEqual(PolicyVerdict.denied_acl_mismatch, evaluateOutboundPolicy(.egress, policy, uri_md, "DELETE", "104.18.40.10"));
    try testing.expectEqual(PolicyVerdict.denied_ssrf_private_ip, evaluateOutboundPolicy(.egress, policy, uri_md, "GET", "169.254.169.254"));
    try testing.expectEqual(PolicyVerdict.denied_driver, evaluateOutboundPolicy(.none, policy, uri_md, "GET", null));
    try testing.expectEqual(PolicyVerdict.denied_driver, evaluateOutboundPolicy(.ingress_only, policy, uri_md, "GET", null));

    const rtmp_uri = ParsedUri.parse("rtmps://ingest.stream.example.com/live/stream_01").?;
    try testing.expectEqual(PolicyVerdict.allowed, evaluateOutboundPolicy(.egress, policy, rtmp_uri, "PUBLISH", null));
}
