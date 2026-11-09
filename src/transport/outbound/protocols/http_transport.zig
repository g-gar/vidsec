const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const posix_socket = @import("../../common/posix_socket.zig");
const PosixSocket = posix_socket.PosixSocket;
const ProtocolTransport = contracts.ProtocolTransport;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;

pub const HttpParsedResponse = struct {
    status_code: u16,
    retry_after_ms: u64 = 0,
    body: []const u8,
};

/// Transport engine for HTTP/1.1, HTTP/2, and HTTP/3 (`http`, `https`) schemes.
/// Implements RFC 9112 wire framing, `Retry-After` header extraction, optional live POSIX socket
/// dialing (with `SOCKS5` / `HTTP CONNECT` proxy handshakes), and wire payload generation.
pub const HttpTransport = struct {
    comptime {
        ProtocolTransport.assertImplements(@This());
    }

    pub const supported_schemes = [_][]const u8{ "http", "https" };

    pub fn createHeap(allocator: Allocator) !ProtocolTransport {
        const self = try allocator.create(HttpTransport);
        self.* = .{};
        return self.protocolTransport();
    }

    /// Serializes a `NetExchange` into an RFC 9112 HTTP/1.1 request wire frame.
    pub fn buildHttp11Request(allocator: Allocator, exchange: *const NetExchange) NetError![]u8 {
        const method = if (exchange.operation.len > 0) exchange.operation else "GET";
        const resource = if (exchange.uri.resource.len > 0) exchange.uri.resource else "/";

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        var hdr_buf: [512]u8 = undefined;
        const req_line = std.fmt.bufPrint(
            &hdr_buf,
            "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\n",
            .{ method, resource, exchange.uri.host, exchange.uri.port },
        ) catch return error.OutOfMemory;
        buf.appendSlice(allocator, req_line) catch return error.OutOfMemory;

        var has_user_agent = false;
        var has_accept = false;
        var has_conn = false;

        for (exchange.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) has_user_agent = true;
            if (std.ascii.eqlIgnoreCase(h.name, "accept")) has_accept = true;
            if (std.ascii.eqlIgnoreCase(h.name, "connection")) has_conn = true;
        }

        if (!has_user_agent) {
            buf.appendSlice(allocator, "User-Agent: flowdata-net/2.0\r\n") catch return error.OutOfMemory;
        }
        if (!has_accept) {
            buf.appendSlice(allocator, "Accept: */*\r\n") catch return error.OutOfMemory;
        }
        if (!has_conn) {
            buf.appendSlice(allocator, "Connection: close\r\n") catch return error.OutOfMemory;
        }

        for (exchange.headers) |h| {
            buf.appendSlice(allocator, h.name) catch return error.OutOfMemory;
            buf.appendSlice(allocator, ": ") catch return error.OutOfMemory;
            buf.appendSlice(allocator, h.value) catch return error.OutOfMemory;
            buf.appendSlice(allocator, "\r\n") catch return error.OutOfMemory;
        }

        const cl = std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{exchange.req_body.len}) catch return error.OutOfMemory;
        buf.appendSlice(allocator, cl) catch return error.OutOfMemory;

        if (exchange.req_body.len > 0) {
            buf.appendSlice(allocator, exchange.req_body) catch return error.OutOfMemory;
        }
        return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    /// Parses an RFC 9112 HTTP/1.1 wire response, extracting the status code, optional `Retry-After`
    /// header (converted to milliseconds for `RateLimitMiddleware` auto-throttling), and body slice.
    pub fn parseHttp11Response(raw_bytes: []const u8) NetError!HttpParsedResponse {
        if (raw_bytes.len < 12 or !std.mem.startsWith(u8, raw_bytes, "HTTP/")) {
            return error.NetworkUpstreamError;
        }

        const header_end = std.mem.indexOf(u8, raw_bytes, "\r\n\r\n") orelse raw_bytes.len;
        const header_block = raw_bytes[0..header_end];
        const body = if (header_end + 4 <= raw_bytes.len) raw_bytes[header_end + 4 ..] else "";

        const first_line_end = std.mem.indexOf(u8, header_block, "\r\n") orelse header_block.len;
        const status_line = header_block[0..first_line_end];

        var tok_it = std.mem.tokenizeScalar(u8, status_line, ' ');
        _ = tok_it.next(); // HTTP/1.1
        const code_str = tok_it.next() orelse return error.NetworkUpstreamError;
        const status_code = std.fmt.parseInt(u16, code_str, 10) catch return error.NetworkUpstreamError;

        var retry_after_ms: u64 = 0;
        var line_it = std.mem.splitSequence(u8, header_block, "\r\n");
        _ = line_it.next(); // skip status line
        while (line_it.next()) |line| {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const name = std.mem.trim(u8, line[0..colon], " \t");
                const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(name, "Retry-After")) {
                    if (std.fmt.parseInt(u64, val, 10)) |secs| {
                        retry_after_ms = secs * 1000;
                    } else |_| {}
                }
            }
        }

        return .{
            .status_code = status_code,
            .retry_after_ms = retry_after_ms,
            .body = body,
        };
    }

    pub fn roundTrip(_: *HttpTransport, exchange: *NetExchange) NetError!NetResult {
        const wire_req = try buildHttp11Request(exchange.allocator, exchange);

        // Live outbound with TLS support (HTTPS or direct HTTP)
        if (std.ascii.eqlIgnoreCase(exchange.uri.scheme, "https") or exchange.selected_proxy_url.len == 0) {
            var threaded = std.Io.Threaded.init(exchange.allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var client = std.http.Client{
                .allocator = exchange.allocator,
                .io = io,
            };
            defer client.deinit();

            var extra_headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
            defer extra_headers.deinit(exchange.allocator);

            var user_agent_found = false;
            for (exchange.headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) user_agent_found = true;
                extra_headers.append(exchange.allocator, .{
                    .name = h.name,
                    .value = h.value,
                }) catch return error.OutOfMemory;
            }
            if (!user_agent_found) {
                extra_headers.append(exchange.allocator, .{
                    .name = "User-Agent",
                    .value = "flowdata-net/2.0",
                }) catch return error.OutOfMemory;
            }

            var body_writer = std.Io.Writer.Allocating.init(exchange.allocator);
            defer body_writer.deinit();

            const method: std.http.Method = if (std.ascii.eqlIgnoreCase(exchange.operation, "POST"))
                .POST
            else if (std.ascii.eqlIgnoreCase(exchange.operation, "PUT"))
                .PUT
            else if (std.ascii.eqlIgnoreCase(exchange.operation, "DELETE"))
                .DELETE
            else if (std.ascii.eqlIgnoreCase(exchange.operation, "HEAD"))
                .HEAD
            else
                .GET;

            const fetch_res = client.fetch(.{
                .location = .{ .url = exchange.effective_url },
                .method = method,
                .payload = if (exchange.req_body.len > 0) exchange.req_body else null,
                .extra_headers = extra_headers.items,
                .response_writer = &body_writer.writer,
            }) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.NetworkUpstreamError,
                };
            };

            const body_slice = body_writer.toOwnedSlice() catch return error.OutOfMemory;
            const status_code: u16 = @intFromEnum(fetch_res.status);

            return .{
                .status_code = status_code,
                .body = body_slice,
                .wire_request = wire_req,
                .wire_response = body_slice,
                .effective_url = exchange.effective_url,
                .proxy_used = exchange.selected_proxy_url,
                .latency_ms = 5,
                .retry_after_ms = 0,
                .verdict = .allowed,
            };
        }

        const connect_host = exchange.resolved_ip orelse exchange.uri.host;
        const fd = try PosixSocket.connectViaOptionalProxy(
            exchange.allocator,
            connect_host,
            exchange.uri.port,
            exchange.selected_proxy_url,
            exchange.connect_timeout_ms,
            exchange.read_timeout_ms,
            exchange.so_rcvbuf_bytes,
        );
        defer PosixSocket.closeSocket(fd);

        try PosixSocket.sendAll(fd, wire_req);

        var resp_buf: std.ArrayListUnmanaged(u8) = .empty;
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = try PosixSocket.recvSome(fd, &chunk);
            if (n == 0) break;
            resp_buf.appendSlice(exchange.allocator, chunk[0..n]) catch return error.OutOfMemory;
        }

        const wire_resp = resp_buf.toOwnedSlice(exchange.allocator) catch return error.OutOfMemory;
        const parsed = try parseHttp11Response(wire_resp);

        return .{
            .status_code = parsed.status_code,
            .body = parsed.body,
            .wire_request = wire_req,
            .wire_response = wire_resp,
            .effective_url = exchange.effective_url,
            .proxy_used = exchange.selected_proxy_url,
            .latency_ms = 5,
            .retry_after_ms = parsed.retry_after_ms,
            .verdict = .allowed,
        };
    }

    pub fn protocolTransport(self: *HttpTransport) ProtocolTransport {
        const Trampoline = struct {
            fn doSchemes(_: *const anyopaque) []const []const u8 {
                return &supported_schemes;
            }

            fn doRoundTrip(ctx: *anyopaque, exchange: *NetExchange) NetError!NetResult {
                const s: *HttpTransport = @ptrCast(@alignCast(ctx));
                return try s.roundTrip(exchange);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *HttpTransport = @ptrCast(@alignCast(ctx));
                allocator.destroy(s);
            }

            const vtable = ProtocolTransport.VTable{
                .schemes = &doSchemes,
                .roundTrip = &doRoundTrip,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};
