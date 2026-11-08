const std = @import("std");

/// RFC 3986 parsed URI representation (`scheme://host:port/resource`).
pub const Uri = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    resource: []const u8,

    pub fn parse(raw_url: []const u8) ?Uri {
        const scheme_end = std.mem.indexOf(u8, raw_url, "://") orelse return null;
        if (scheme_end == 0) return null;
        const scheme = raw_url[0..scheme_end];
        const rest = raw_url[scheme_end + 3 ..];

        const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..slash_idx];
        const resource = if (slash_idx < rest.len) rest[slash_idx..] else "/";

        const host_port = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
            authority[at + 1 ..]
        else
            authority;

        if (host_port.len == 0) return null;

        var host: []const u8 = host_port;
        var port: u16 = defaultPortForScheme(scheme);

        if (host_port[0] == '[') {
            const close_bracket = std.mem.indexOfScalar(u8, host_port, ']') orelse return null;
            host = host_port[1..close_bracket];
            if (close_bracket + 1 < host_port.len and host_port[close_bracket + 1] == ':') {
                port = std.fmt.parseInt(u16, host_port[close_bracket + 2 ..], 10) catch return null;
            }
        } else if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon_idx| {
            host = host_port[0..colon_idx];
            port = std.fmt.parseInt(u16, host_port[colon_idx + 1 ..], 10) catch return null;
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
        if (std.ascii.eqlIgnoreCase(scheme, "https") or
            std.ascii.eqlIgnoreCase(scheme, "wss") or
            std.ascii.eqlIgnoreCase(scheme, "grpcs") or
            std.ascii.eqlIgnoreCase(scheme, "rtmps") or
            std.ascii.eqlIgnoreCase(scheme, "tls") or
            std.ascii.eqlIgnoreCase(scheme, "quic"))
        {
            return 443;
        }
        if (std.ascii.eqlIgnoreCase(scheme, "http") or
            std.ascii.eqlIgnoreCase(scheme, "ws") or
            std.ascii.eqlIgnoreCase(scheme, "grpc"))
        {
            return 80;
        }
        if (std.ascii.eqlIgnoreCase(scheme, "rtmp")) return 1935;
        if (std.ascii.eqlIgnoreCase(scheme, "rtsp")) return 554;
        if (std.ascii.eqlIgnoreCase(scheme, "amqp")) return 5672;
        if (std.ascii.eqlIgnoreCase(scheme, "socks5")) return 1080;
        return 80;
    }
};
