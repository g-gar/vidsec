const std = @import("std");
const Allocator = std.mem.Allocator;
const Uri = @import("uri.zig").Uri;

pub const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/time.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("unistd.h");
});

pub const PosixSocketError = error{
    InvalidUri,
    UnsupportedProtocolScheme,
    NetworkPolicyDenied,
    NetworkRateLimited,
    NetworkAcquireTimeout,
    NetworkUpstreamError,
    StreamNotFound,
    OutOfMemory,
};

/// Low-level POSIX socket dialer, TCP window backpressure configurator (`SO_RCVBUF`),
/// and proxy tunnel handshaker (`SOCKS5` RFC 1928 & `HTTP CONNECT`).
pub const PosixSocket = struct {
    /// Applies kernel TCP receive buffer size (`SO_RCVBUF`) and read/write timeouts (`SO_RCVTIMEO`/`SO_SNDTIMEO`).
    pub fn configureSocketOptions(
        fd: c_int,
        connect_timeout_ms: u64,
        read_timeout_ms: u64,
        so_rcvbuf_bytes: usize,
    ) void {
        if (so_rcvbuf_bytes > 0) {
            var rcvbuf: c_int = @intCast(@min(so_rcvbuf_bytes, 16 * 1024 * 1024));
            _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVBUF, &rcvbuf, @sizeOf(c_int));
        }

        if (connect_timeout_ms > 0) {
            var snd_tv = c.struct_timeval{
                .tv_sec = @intCast(connect_timeout_ms / 1000),
                .tv_usec = @intCast((connect_timeout_ms % 1000) * 1000),
            };
            _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &snd_tv, @sizeOf(c.struct_timeval));
        }

        if (read_timeout_ms > 0) {
            var rcv_tv = c.struct_timeval{
                .tv_sec = @intCast(read_timeout_ms / 1000),
                .tv_usec = @intCast((read_timeout_ms % 1000) * 1000),
            };
            _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &rcv_tv, @sizeOf(c.struct_timeval));
        }
    }

    /// Dials a TCP connection to `host:port` using POSIX `getaddrinfo` + `socket` + `connect`.
    pub fn dialTcp(
        allocator: Allocator,
        host: []const u8,
        port: u16,
        connect_timeout_ms: u64,
        read_timeout_ms: u64,
        so_rcvbuf_bytes: usize,
    ) PosixSocketError!c_int {
        const host_z = allocator.dupeZ(u8, host) catch return error.OutOfMemory;
        defer allocator.free(host_z);

        var port_buf: [16:0]u8 = undefined;
        const port_z = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return error.InvalidUri;

        var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
        hints.ai_family = c.AF_UNSPEC;
        hints.ai_socktype = c.SOCK_STREAM;

        var res: ?*c.struct_addrinfo = null;
        if (c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res) != 0 or res == null) {
            return error.NetworkUpstreamError;
        }
        defer c.freeaddrinfo(res);

        var cur = res;
        while (cur) |ai| : (cur = ai.ai_next) {
            const fd = c.socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol);
            if (fd < 0) continue;

            configureSocketOptions(fd, connect_timeout_ms, read_timeout_ms, so_rcvbuf_bytes);

            if (c.connect(fd, ai.ai_addr, ai.ai_addrlen) == 0) {
                return fd;
            }
            _ = c.close(fd);
        }

        return error.NetworkUpstreamError;
    }

    /// Builds an RFC 1928 SOCKS5 No-Auth Greeting (`[0x05, 0x01, 0x00]`).
    pub fn buildSocks5Greeting() [3]u8 {
        return .{ 0x05, 0x01, 0x00 };
    }

    /// Builds an RFC 1928 SOCKS5 Domain-Name CONNECT request frame (`ATYP = 0x03`).
    pub fn buildSocks5ConnectRequest(buf: []u8, dst_host: []const u8, dst_port: u16) PosixSocketError![]const u8 {
        if (dst_host.len == 0 or dst_host.len > 255) return error.InvalidUri;
        const total_len = 4 + 1 + dst_host.len + 2;
        if (buf.len < total_len) return error.OutOfMemory;

        buf[0] = 0x05; // VER = SOCKS5
        buf[1] = 0x01; // CMD = CONNECT
        buf[2] = 0x00; // RSV
        buf[3] = 0x03; // ATYP = DOMAINNAME
        buf[4] = @intCast(dst_host.len);
        @memcpy(buf[5 .. 5 + dst_host.len], dst_host);
        std.mem.writeInt(u16, buf[5 + dst_host.len ..][0..2], dst_port, .big);
        return buf[0..total_len];
    }

    /// Performs an RFC 1928 SOCKS5 tunnel handshake over an connected socket `fd`.
    pub fn handshakeSocks5(fd: c_int, dst_host: []const u8, dst_port: u16) PosixSocketError!void {
        const greeting = buildSocks5Greeting();
        try sendAll(fd, &greeting);

        var method_resp: [2]u8 = undefined;
        try recvExact(fd, &method_resp);
        if (method_resp[0] != 0x05 or method_resp[1] != 0x00) {
            return error.NetworkUpstreamError;
        }

        var req_buf: [300]u8 = undefined;
        const req_frame = try buildSocks5ConnectRequest(&req_buf, dst_host, dst_port);
        try sendAll(fd, req_frame);

        var hdr_resp: [4]u8 = undefined;
        try recvExact(fd, &hdr_resp);
        if (hdr_resp[0] != 0x05 or hdr_resp[1] != 0x00) {
            return error.NetworkUpstreamError;
        }

        // Consume bound address + port based on ATYP
        switch (hdr_resp[3]) {
            0x01 => { // IPv4 (4 + 2 bytes)
                var rest: [6]u8 = undefined;
                try recvExact(fd, &rest);
            },
            0x03 => { // Domain name
                var len_byte: [1]u8 = undefined;
                try recvExact(fd, &len_byte);
                var skip_buf: [257]u8 = undefined;
                const to_read = @as(usize, len_byte[0]) + 2;
                try recvExact(fd, skip_buf[0..to_read]);
            },
            0x04 => { // IPv6 (16 + 2 bytes)
                var rest: [18]u8 = undefined;
                try recvExact(fd, &rest);
            },
            else => return error.NetworkUpstreamError,
        }
    }

    /// Builds an HTTP/1.1 `CONNECT host:port HTTP/1.1` tunnel request frame.
    pub fn buildHttpConnectRequest(buf: []u8, dst_host: []const u8, dst_port: u16) PosixSocketError![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\nProxy-Connection: keep-alive\r\n\r\n",
            .{ dst_host, dst_port, dst_host, dst_port },
        ) catch error.OutOfMemory;
    }

    /// Performs an HTTP `CONNECT` proxy tunnel handshake over `fd`.
    pub fn handshakeHttpConnect(fd: c_int, dst_host: []const u8, dst_port: u16) PosixSocketError!void {
        var req_buf: [512]u8 = undefined;
        const req_frame = try buildHttpConnectRequest(&req_buf, dst_host, dst_port);
        try sendAll(fd, req_frame);

        var resp_buf: [1024]u8 = undefined;
        const n = try recvSome(fd, &resp_buf);
        if (n < 12) return error.NetworkUpstreamError;
        const resp_txt = resp_buf[0..n];
        if (!std.mem.startsWith(u8, resp_txt, "HTTP/1.1 200") and
            !std.mem.startsWith(u8, resp_txt, "HTTP/1.0 200"))
        {
            return error.NetworkUpstreamError;
        }
    }

    /// Connects either directly to `dst_host:dst_port` or via `proxy_url` (`socks5://` or `http://`).
    pub fn connectViaOptionalProxy(
        allocator: Allocator,
        dst_host: []const u8,
        dst_port: u16,
        proxy_url: []const u8,
        connect_timeout_ms: u64,
        read_timeout_ms: u64,
        so_rcvbuf_bytes: usize,
    ) PosixSocketError!c_int {
        if (proxy_url.len == 0) {
            return try dialTcp(allocator, dst_host, dst_port, connect_timeout_ms, read_timeout_ms, so_rcvbuf_bytes);
        }

        const proxy_uri = Uri.parse(proxy_url) orelse return error.InvalidUri;
        const fd = try dialTcp(allocator, proxy_uri.host, proxy_uri.port, connect_timeout_ms, read_timeout_ms, so_rcvbuf_bytes);
        errdefer closeSocket(fd);

        if (std.ascii.eqlIgnoreCase(proxy_uri.scheme, "socks5") or std.ascii.eqlIgnoreCase(proxy_uri.scheme, "socks5h")) {
            try handshakeSocks5(fd, dst_host, dst_port);
        } else if (std.ascii.eqlIgnoreCase(proxy_uri.scheme, "http") or std.ascii.eqlIgnoreCase(proxy_uri.scheme, "https")) {
            try handshakeHttpConnect(fd, dst_host, dst_port);
        } else {
            return error.UnsupportedProtocolScheme;
        }

        return fd;
    }

    pub fn sendAll(fd: c_int, data: []const u8) PosixSocketError!void {
        var sent: usize = 0;
        while (sent < data.len) {
            const rc = c.send(fd, data[sent..].ptr, data.len - sent, 0);
            if (rc <= 0) return error.NetworkUpstreamError;
            sent += @intCast(rc);
        }
    }

    pub fn recvSome(fd: c_int, buf: []u8) PosixSocketError!usize {
        if (buf.len == 0) return 0;
        const rc = c.recv(fd, buf.ptr, buf.len, 0);
        if (rc < 0) return error.NetworkUpstreamError;
        return @intCast(rc);
    }

    pub fn recvExact(fd: c_int, buf: []u8) PosixSocketError!void {
        var got: usize = 0;
        while (got < buf.len) {
            const n = try recvSome(fd, buf[got..]);
            if (n == 0) return error.NetworkUpstreamError;
            got += n;
        }
    }

    pub fn closeSocket(fd: c_int) void {
        if (fd >= 0) {
            _ = c.close(fd);
        }
    }
};
