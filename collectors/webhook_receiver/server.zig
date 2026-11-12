const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("collectors_common");
const JobEnvelope = common.JobEnvelope;
const SpoolForwarder = common.SpoolForwarder;

const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("errno.h");
});

/// Foreground HTTP server receiving webhooks and forwarding them to Flowdata with store-and-forward spooling.
pub const WebhookServer = struct {
    allocator: Allocator,
    host: []const u8,
    port: u16,
    forwarder: *SpoolForwarder,
    is_running: std.atomic.Value(bool),

    pub fn init(
        allocator: Allocator,
        host: []const u8,
        port: u16,
        forwarder: *SpoolForwarder,
    ) WebhookServer {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .forwarder = forwarder,
            .is_running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn stop(self: *WebhookServer) void {
        self.is_running.store(false, .release);
    }

    /// Runs the HTTP listening loop in the foreground until interrupted.
    pub fn run(self: *WebhookServer) !void {
        const server_fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (server_fd < 0) return error.SocketCreationFailed;
        defer _ = c.close(server_fd);

        var opt: c_int = 1;
        _ = c.setsockopt(server_fd, c.SOL_SOCKET, c.SO_REUSEADDR, &opt, @sizeOf(c_int));

        var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
        addr.sin_family = c.AF_INET;
        addr.sin_port = std.mem.nativeToBig(u16, self.port);
        addr.sin_addr.s_addr = c.INADDR_ANY;

        if (c.bind(server_fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) < 0) {
            std.debug.print("[Webhook ERROR] Failed to bind to {s}:{d}\n", .{ self.host, self.port });
            return error.BindFailed;
        }

        if (c.listen(server_fd, 128) < 0) {
            return error.ListenFailed;
        }

        std.debug.print("[Webhook] Server listening on http://{s}:{d}\n", .{ self.host, self.port });

        var poll_fds = [_]c.struct_pollfd{
            .{
                .fd = server_fd,
                .events = c.POLLIN,
                .revents = 0,
            },
        };

        while (self.is_running.load(.acquire)) {
            // Periodic flush attempt in case Flowdata came back online
            _ = self.forwarder.flush() catch {};

            // 500ms poll timeout for graceful shutdown on Ctrl+C and periodic flush
            const poll_res = c.poll(&poll_fds, 1, 500);
            if (poll_res <= 0) continue;

            if (poll_fds[0].revents & c.POLLIN != 0) {
                var client_addr: c.struct_sockaddr_in = undefined;
                var client_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
                const client_fd = c.accept(server_fd, @ptrCast(&client_addr), &client_len);
                if (client_fd < 0) continue;

                self.handleClient(client_fd);
                _ = c.close(client_fd);
            }
        }

        std.debug.print("[Webhook] Server stopped gracefully.\n", .{});
    }

    fn handleClient(self: *WebhookServer, client_fd: c_int) void {
        var req_buf: [65536]u8 = undefined;
        const n = c.recv(client_fd, &req_buf, req_buf.len - 1, 0);
        if (n <= 0) return;
        req_buf[@intCast(n)] = 0;
        const req_data = req_buf[0..@intCast(n)];

        // Parse first line: METHOD PATH HTTP/1.x
        const first_line_end = std.mem.indexOf(u8, req_data, "\r\n") orelse (std.mem.indexOfScalar(u8, req_data, '\n') orelse return);
        const first_line = req_data[0..first_line_end];

        var it = std.mem.splitScalar(u8, first_line, ' ');
        const method = it.next() orelse return;
        const target = it.next() orelse return;

        // Health check endpoint
        if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, target, "/health") or std.mem.eql(u8, target, "/v1/health"))) {
            const spooled_count = self.forwarder.spool.count();
            var resp_buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&resp_buf, "{{\"status\":\"ok\",\"spooled\":{d}}}\n", .{spooled_count}) catch return;

            var header_buf: [256]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;

            _ = sendAll(client_fd, header);
            _ = sendAll(client_fd, body);
            return;
        }

        if (!std.mem.eql(u8, method, "POST")) {
            const not_allowed = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = sendAll(client_fd, not_allowed);
            return;
        }

        // Target path parsing: e.g. "/webhook/:topic"
        var topic: []const u8 = "general";
        if (std.mem.startsWith(u8, target, "/webhook/")) {
            topic = target["/webhook/".len..];
            if (std.mem.indexOfScalar(u8, topic, '?')) |q_idx| {
                topic = topic[0..q_idx];
            }
        } else if (std.mem.eql(u8, target, "/webhook")) {
            topic = "general";
        }

        // Separate body from headers
        var body: []const u8 = "";
        if (std.mem.indexOf(u8, req_data, "\r\n\r\n")) |header_end| {
            body = req_data[header_end + 4 ..];
        } else if (std.mem.indexOf(u8, req_data, "\n\n")) |header_end| {
            body = req_data[header_end + 2 ..];
        }

        const ts: u64 = common.currentTimestampNs();
        const ulid_str = common.Ulid.generate();
        var id_buf: [64]u8 = undefined;
        var job_id: []const u8 = std.fmt.bufPrint(&id_buf, "wh_{s}", .{ulid_str}) catch &ulid_str;

        // Respect client idempotency / request ID headers if supplied
        if (extractHeaderValue(req_data, "X-Request-ID:") orelse
            extractHeaderValue(req_data, "x-request-id:") orelse
            extractHeaderValue(req_data, "Idempotency-Key:") orelse
            extractHeaderValue(req_data, "idempotency-key:")) |client_id|
        {
            if (client_id.len > 0 and client_id.len <= 64) {
                job_id = client_id;
            }
        }

        const job = JobEnvelope{
            .id = job_id,
            .datasource = "webhook",
            .topic = topic,
            .timestamp_ns = ts,
            .params = &.{},
            .payload_raw = if (body.len > 0) body else null,
        };

        const result = self.forwarder.send(job) catch |err| {
            std.debug.print("[Webhook ERROR] Failed to send/spool job: {s}\n", .{@errorName(err)});
            const err_resp = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = sendAll(client_fd, err_resp);
            return;
        };

        var body_resp_buf: [256]u8 = undefined;
        var header_resp_buf: [256]u8 = undefined;

        if (result.delivered) {
            const resp_body = std.fmt.bufPrint(&body_resp_buf, "{{\"status\":\"delivered\",\"id\":\"{s}\",\"topic\":\"{s}\"}}\n", .{ job_id, topic }) catch return;
            const resp_header = std.fmt.bufPrint(&header_resp_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{resp_body.len}) catch return;
            _ = sendAll(client_fd, resp_header);
            _ = sendAll(client_fd, resp_body);
        } else {
            // Spooled for store-and-forward resilience
            const resp_body = std.fmt.bufPrint(&body_resp_buf, "{{\"status\":\"spooled\",\"id\":\"{s}\",\"topic\":\"{s}\"}}\n", .{ job_id, topic }) catch return;
            const resp_header = std.fmt.bufPrint(&header_resp_buf, "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{resp_body.len}) catch return;
            _ = sendAll(client_fd, resp_header);
            _ = sendAll(client_fd, resp_body);
        }
    }

    fn sendAll(fd: c_int, data: []const u8) bool {
        var sent: usize = 0;
        while (sent < data.len) {
            const rc = c.send(fd, data.ptr + sent, data.len - sent, 0);
            if (rc <= 0) return false;
            sent += @intCast(rc);
        }
        return true;
    }

    fn extractHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
        if (std.mem.indexOf(u8, headers, name)) |idx| {
            const after_key = headers[idx + name.len ..];
            const line_end = std.mem.indexOfScalar(u8, after_key, '\r') orelse (std.mem.indexOfScalar(u8, after_key, '\n') orelse after_key.len);
            return std.mem.trim(u8, after_key[0..line_end], " \t\r\n");
        }
        return null;
    }
};
