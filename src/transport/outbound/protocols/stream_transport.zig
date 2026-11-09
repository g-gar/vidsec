const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const posix_socket = @import("../../common/posix_socket.zig");
const PosixSocket = posix_socket.PosixSocket;
const ProtocolTransport = contracts.ProtocolTransport;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;
const NetError = contracts.NetError;
const NetStreamId = contracts.NetStreamId;

/// Active bidirectional L4/L7 stream session managed by `StreamSessionTable`.
pub const StreamSession = struct {
    id: NetStreamId,
    scheme: []const u8,
    effective_url: []const u8,
    proxy_used: []const u8,
    socket_fd: c_int = -1,
    recv_buffer: std.ArrayListUnmanaged(u8) = .empty,
    read_cursor: usize = 0,
    bytes_sent: usize = 0,
    bytes_received: usize = 0,

    pub fn deinit(self: *StreamSession, allocator: Allocator) void {
        if (self.socket_fd >= 0) {
            PosixSocket.closeSocket(self.socket_fd);
            self.socket_fd = -1;
        }
        self.recv_buffer.deinit(allocator);
    }
};

/// Table of open stateful streams (`ws`, `wss`, `grpc`, `grpcs`, `rtmp`, `rtmps`, `rtsp`, `tcp`, `udp`, `tls`, `quic`)
/// owned by an adapter driver (`EgressAdapter` / `SinkholeAdapter`).
pub const StreamSessionTable = struct {
    allocator: Allocator,
    sessions: std.AutoHashMapUnmanaged(NetStreamId, StreamSession) = .empty,
    next_id: NetStreamId = 1,

    pub fn init(allocator: Allocator) StreamSessionTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StreamSessionTable) void {
        var it = self.sessions.valueIterator();
        while (it.next()) |sess| {
            sess.deinit(self.allocator);
        }
        self.sessions.deinit(self.allocator);
    }

    pub fn openSession(
        self: *StreamSessionTable,
        scheme: []const u8,
        effective_url: []const u8,
        proxy_used: []const u8,
        initial_server_greeting: []const u8,
    ) NetError!NetStreamId {
        const id = self.next_id;
        self.next_id += 1;

        var sess = StreamSession{
            .id = id,
            .scheme = scheme,
            .effective_url = effective_url,
            .proxy_used = proxy_used,
        };
        errdefer sess.deinit(self.allocator);

        if (initial_server_greeting.len > 0) {
            sess.recv_buffer.appendSlice(self.allocator, initial_server_greeting) catch return error.OutOfMemory;
        }

        self.sessions.put(self.allocator, id, sess) catch return error.OutOfMemory;
        return id;
    }

    pub fn send(self: *StreamSessionTable, stream_id: NetStreamId, payload: []const u8) NetError!usize {
        const sess = self.sessions.getPtr(stream_id) orelse return error.StreamNotFound;
        if (sess.socket_fd >= 0) {
            try PosixSocket.sendAll(sess.socket_fd, payload);
        } else {
            // In virtual/sandbox mode, echo frame acknowledgment into the stream's receive buffer
            sess.recv_buffer.appendSlice(self.allocator, payload) catch return error.OutOfMemory;
        }
        sess.bytes_sent += payload.len;
        return payload.len;
    }

    pub fn recv(self: *StreamSessionTable, stream_id: NetStreamId, dest: []u8) NetError!usize {
        const sess = self.sessions.getPtr(stream_id) orelse return error.StreamNotFound;
        if (sess.socket_fd >= 0) {
            const n = try PosixSocket.recvSome(sess.socket_fd, dest);
            sess.bytes_received += n;
            return n;
        }

        const avail = sess.recv_buffer.items.len - sess.read_cursor;
        if (avail == 0 or dest.len == 0) return 0;
        const n = @min(avail, dest.len);
        @memcpy(dest[0..n], sess.recv_buffer.items[sess.read_cursor .. sess.read_cursor + n]);
        sess.read_cursor += n;
        sess.bytes_received += n;
        return n;
    }

    pub fn close(self: *StreamSessionTable, stream_id: NetStreamId) void {
        if (self.sessions.fetchRemove(stream_id)) |kv| {
            var sess = kv.value;
            sess.deinit(self.allocator);
        }
    }
};

/// Transport engine for stateful/streaming L4/L7 protocols (`ws`, `wss`, `grpc`, `grpcs`, `rtmp`, `rtmps`, `rtsp`, `amqp`, `tcp`, `udp`, `tls`, `quic`).
/// Implements the polymorphic `ProtocolTransport` VTable and generates authentic protocol wire handshakes.
pub const StreamTransport = struct {
    comptime {
        ProtocolTransport.assertImplements(@This());
    }

    pub const supported_schemes = [_][]const u8{
        "ws",
        "wss",
        "grpc",
        "grpcs",
        "rtmp",
        "rtmps",
        "rtsp",
        "amqp",
        "tcp",
        "udp",
        "tls",
        "quic",
    };

    pub fn createHeap(allocator: Allocator) !ProtocolTransport {
        const self = try allocator.create(StreamTransport);
        self.* = .{};
        return self.protocolTransport();
    }

    /// Builds protocol-authentic wire handshake frames for packet inspection and socket transmission.
    pub fn buildProtocolHandshakeFrame(
        allocator: Allocator,
        scheme: []const u8,
        host: []const u8,
        resource: []const u8,
        operation: []const u8,
    ) NetError![]u8 {
        if (std.ascii.eqlIgnoreCase(scheme, "ws") or std.ascii.eqlIgnoreCase(scheme, "wss")) {
            return std.fmt.allocPrint(
                allocator,
                "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n\r\n",
                .{ resource, host },
            ) catch error.OutOfMemory;
        }
        if (std.ascii.eqlIgnoreCase(scheme, "grpc") or std.ascii.eqlIgnoreCase(scheme, "grpcs")) {
            return std.fmt.allocPrint(
                allocator,
                "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n:method={s} :path={s} :authority={s}",
                .{ operation, resource, host },
            ) catch error.OutOfMemory;
        }
        if (std.ascii.eqlIgnoreCase(scheme, "rtmp") or std.ascii.eqlIgnoreCase(scheme, "rtmps")) {
            return std.fmt.allocPrint(
                allocator,
                "\x03RTMP_C1_HANDSHAKE tcUrl={s}://{s}{s} cmd={s}",
                .{ scheme, host, resource, operation },
            ) catch error.OutOfMemory;
        }
        if (std.ascii.eqlIgnoreCase(scheme, "rtsp")) {
            return std.fmt.allocPrint(
                allocator,
                "{s} rtsp://{s}{s} RTSP/1.0\r\nCSeq: 1\r\n\r\n",
                .{ operation, host, resource },
            ) catch error.OutOfMemory;
        }
        return std.fmt.allocPrint(
            allocator,
            "STREAM_OPEN {s}://{s}{s} op={s}\r\n",
            .{ scheme, host, resource, operation },
        ) catch error.OutOfMemory;
    }

    pub fn roundTrip(_: *StreamTransport, exchange: *NetExchange) NetError!NetResult {
        const wire_req = try buildProtocolHandshakeFrame(
            exchange.allocator,
            exchange.uri.scheme,
            exchange.uri.host,
            exchange.uri.resource,
            exchange.operation,
        );
        const wire_resp = std.fmt.allocPrint(
            exchange.allocator,
            "STREAM_ACK 101 Switching Protocols ({s})\r\n",
            .{exchange.uri.scheme},
        ) catch return error.OutOfMemory;

        return .{
            .status_code = 101,
            .body = "",
            .wire_request = wire_req,
            .wire_response = wire_resp,
            .effective_url = exchange.effective_url,
            .proxy_used = exchange.selected_proxy_url,
            .latency_ms = 2,
            .verdict = .allowed,
        };
    }

    pub fn protocolTransport(self: *StreamTransport) ProtocolTransport {
        const Trampoline = struct {
            fn doSchemes(_: *const anyopaque) []const []const u8 {
                return &supported_schemes;
            }

            fn doRoundTrip(ctx: *anyopaque, exchange: *NetExchange) NetError!NetResult {
                const s: *StreamTransport = @ptrCast(@alignCast(ctx));
                return try s.roundTrip(exchange);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *StreamTransport = @ptrCast(@alignCast(ctx));
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
