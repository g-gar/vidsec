const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const contracts = flowdata.transport.inbound.contracts;
const registry_mod = flowdata.transport.inbound.registry;
const posix_socket = flowdata.transport.common.posix_socket;

pub const InboundTransport = contracts.InboundTransport;
pub const HostTransport = contracts.HostTransport;
pub const InvocationRequest = contracts.InvocationRequest;
pub const InvocationResponse = contracts.InvocationResponse;
pub const InvocationCommand = contracts.InvocationCommand;
pub const OutputFormat = contracts.OutputFormat;
pub const InboundTransportConfig = registry_mod.InboundTransportConfig;
pub const NetworkTimeouts = flowdata.transport.NetworkTimeouts;

const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
});

/// High-performance HTTP REST Transport for Flowdata pipelines.
/// Exposes daemon endpoints (`/v1/health`, `/v1/validate`, `/v1/run`, `/v1/custom/*`) and converts incoming HTTP requests
/// to agnostic `InvocationRequest` envelopes.
pub const HttpServerTransport = struct {
    comptime {
        InboundTransport.assertImplements(@This());
    }

    allocator: Allocator,
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 8080,
    default_pipeline_path: []const u8 = "",
    timeouts: NetworkTimeouts = .{},
    is_heap_allocated: bool = false,

    pub fn init(
        allocator: Allocator,
        listen_host: []const u8,
        listen_port: u16,
        default_pipeline_path: []const u8,
    ) HttpServerTransport {
        return .{
            .allocator = allocator,
            .listen_host = listen_host,
            .listen_port = listen_port,
            .default_pipeline_path = default_pipeline_path,
            .timeouts = .{},
            .is_heap_allocated = false,
        };
    }

    pub fn initWithTimeouts(
        allocator: Allocator,
        listen_host: []const u8,
        listen_port: u16,
        default_pipeline_path: []const u8,
        timeouts: NetworkTimeouts,
    ) HttpServerTransport {
        return .{
            .allocator = allocator,
            .listen_host = listen_host,
            .listen_port = listen_port,
            .default_pipeline_path = default_pipeline_path,
            .timeouts = timeouts,
            .is_heap_allocated = false,
        };
    }

    pub fn createDaemon(allocator: Allocator, config: InboundTransportConfig) anyerror!InboundTransport {
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 8080;
        if (std.mem.indexOfScalar(u8, config.listen_address, ':')) |colon| {
            host = config.listen_address[0..colon];
            port = std.fmt.parseInt(u16, config.listen_address[colon + 1 ..], 10) catch 8080;
        } else if (std.fmt.parseInt(u16, config.listen_address, 10) catch null) |p| {
            port = p;
        }
        const s = try allocator.create(HttpServerTransport);
        s.* = HttpServerTransport.initWithTimeouts(allocator, host, port, config.pipeline_path, config.timeouts);
        s.is_heap_allocated = true;
        return s.inboundTransport();
    }

    pub fn inboundTransport(self: *HttpServerTransport) InboundTransport {
        const Trampoline = struct {
            fn doName(_: *const anyopaque) []const u8 {
                return "http";
            }

            fn doServe(
                ctx: *anyopaque,
                dispatcher_ctx: contracts.DispatcherPtr,
                dispatch_fn: contracts.DispatchFn,
            ) anyerror!u8 {
                const s: *HttpServerTransport = @ptrCast(@alignCast(ctx));
                return s.serveLoop(dispatcher_ctx, dispatch_fn);
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *HttpServerTransport = @ptrCast(@alignCast(ctx));
                if (s.is_heap_allocated) {
                    allocator.destroy(s);
                }
            }

            const vtable = InboundTransport.VTable{
                .name = &doName,
                .serve = &doServe,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }

    pub const hostTransport = inboundTransport;

    /// Processes a raw HTTP/1.x wire request buffer in-memory and formats a complete HTTP/1.x response.
    /// Useful both for deterministic unit testing and socket request dispatching.
    pub fn handleHttpRequest(
        self: *HttpServerTransport,
        allocator: Allocator,
        raw_request: []const u8,
        dispatcher_ctx: contracts.DispatcherPtr,
        dispatch_fn: contracts.DispatchFn,
    ) anyerror![]u8 {
        if (raw_request.len < 10) {
            return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"malformed_request\"}\n");
        }

        const header_end = std.mem.indexOf(u8, raw_request, "\r\n\r\n") orelse raw_request.len;
        const headers_part = raw_request[0..header_end];
        const body = if (header_end + 4 <= raw_request.len) raw_request[header_end + 4 ..] else "";

        const first_line_end = std.mem.indexOf(u8, headers_part, "\r\n") orelse headers_part.len;
        const req_line = headers_part[0..first_line_end];

        var line_tok = std.mem.tokenizeScalar(u8, req_line, ' ');
        const method = line_tok.next() orelse return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"missing_method\"}\n");
        const path = line_tok.next() orelse "/";

        // Read optional custom headers
        var custom_pipe_path: ?[]const u8 = null;
        var skip_so: bool = false;
        var line_it = std.mem.splitSequence(u8, headers_part, "\r\n");
        _ = line_it.next(); // Skip request line
        while (line_it.next()) |hdr| {
            if (std.mem.indexOfScalar(u8, hdr, ':')) |colon| {
                const h_name = std.mem.trim(u8, hdr[0..colon], " \t");
                const h_val = std.mem.trim(u8, hdr[colon + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(h_name, "x-pipeline-path")) {
                    custom_pipe_path = h_val;
                } else if (std.ascii.eqlIgnoreCase(h_name, "x-skip-so")) {
                    if (std.ascii.eqlIgnoreCase(h_val, "true") or std.mem.eql(u8, h_val, "1")) {
                        skip_so = true;
                    }
                }
            }
        }

        const effective_pipeline = if (custom_pipe_path) |p| p else self.default_pipeline_path;

        // Route: GET /v1/health or /health
        if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path, "/v1/health") or std.mem.eql(u8, path, "/health"))) {
            const resp = try dispatch_fn(dispatcher_ctx, .{
                .command = .health,
                .format = .json,
                .options = .{ .pipeline_yaml_path = effective_pipeline },
            });
            return formatHttpResponse(allocator, 200, "OK", resp.output_bytes);
        }

        // Route: GET /v1/version or /version
        if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path, "/v1/version") or std.mem.eql(u8, path, "/version"))) {
            const resp = try dispatch_fn(dispatcher_ctx, .{
                .command = .version,
                .format = .json,
                .options = .{ .pipeline_yaml_path = effective_pipeline },
            });
            return formatHttpResponse(allocator, 200, "OK", resp.output_bytes);
        }

        // Route: POST /v1/validate
        if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/v1/validate")) {
            if (effective_pipeline.len == 0) {
                return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"missing_pipeline_path\"}\n");
            }
            const resp = try dispatch_fn(dispatcher_ctx, .{
                .command = .validate,
                .format = .json,
                .options = .{
                    .pipeline_yaml_path = effective_pipeline,
                    .load_shared_modules = !skip_so,
                },
            });
            const status_code: u16 = if (resp.status == .ok) 200 else 400;
            return formatHttpResponse(allocator, status_code, if (resp.status == .ok) "OK" else "Validation Error", resp.output_bytes);
        }

        // Route: POST /v1/run
        if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/v1/run")) {
            if (effective_pipeline.len == 0) {
                return formatHttpResponse(allocator, 400, "Bad Request", "{\"error\":\"missing_pipeline_path\"}\n");
            }

            const input_src: contracts.InputSource = if (body.len > 0)
                .{ .memory_bytes = body }
            else
                .none;

            const resp = try dispatch_fn(dispatcher_ctx, .{
                .command = .run,
                .format = .json,
                .input = input_src,
                .options = .{
                    .pipeline_yaml_path = effective_pipeline,
                    .load_shared_modules = !skip_so,
                },
            });

            const status_code: u16 = if (resp.status == .ok) 200 else 500;
            return formatHttpResponse(allocator, status_code, if (resp.status == .ok) "OK" else "Execution Failed", resp.output_bytes);
        }

        // Route: custom commands, e.g. POST /v1/custom/{cmd_name}
        if (std.mem.startsWith(u8, path, "/v1/custom/")) {
            const custom_name = path["/v1/custom/".len..];
            const resp = try dispatch_fn(dispatcher_ctx, .{
                .command = .custom,
                .custom_command_name = custom_name,
                .format = .json,
                .input = if (body.len > 0) .{ .memory_bytes = body } else .none,
                .options = .{ .pipeline_yaml_path = effective_pipeline },
            });
            const status_code: u16 = if (resp.status == .ok) 200 else 404;
            return formatHttpResponse(allocator, status_code, if (resp.status == .ok) "OK" else "Not Found", resp.output_bytes);
        }

        return formatHttpResponse(allocator, 404, "Not Found", "{\"error\":\"not_found\"}\n");
    }

    /// Serves incoming HTTP connections on a POSIX socket.
    pub fn serveLoop(
        self: *HttpServerTransport,
        dispatcher_ctx: contracts.DispatcherPtr,
        dispatch_fn: contracts.DispatchFn,
    ) anyerror!u8 {
        const sock_fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (sock_fd < 0) return error.SocketCreateFailed;
        defer _ = c.close(sock_fd);

        var opt: c_int = 1;
        _ = c.setsockopt(sock_fd, c.SOL_SOCKET, c.SO_REUSEADDR, &opt, @sizeOf(c_int));

        var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
        addr.sin_family = c.AF_INET;
        addr.sin_port = std.mem.nativeToBig(u16, self.listen_port);
        addr.sin_addr.s_addr = c.INADDR_ANY;

        if (c.bind(sock_fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0) {
            return error.BindFailed;
        }

        if (c.listen(sock_fd, 64) != 0) {
            return error.ListenFailed;
        }

        var buf: [65536]u8 = undefined;
        while (true) {
            const client_fd = c.accept(sock_fd, null, null);
            if (client_fd < 0) continue;
            defer _ = c.close(client_fd);

            posix_socket.PosixSocket.configureSocketOptions(
                client_fd,
                self.timeouts.connect_ms,
                self.timeouts.read_idle_ms,
                0,
            );

            const n = c.recv(client_fd, &buf, buf.len, 0);
            if (n <= 0) continue;

            const resp_bytes = try self.handleHttpRequest(
                self.allocator,
                buf[0..@intCast(n)],
                dispatcher_ctx,
                dispatch_fn,
            );
            defer self.allocator.free(resp_bytes);

            _ = c.send(client_fd, resp_bytes.ptr, resp_bytes.len, 0);
        }
    }
};

pub const HttpTransport = HttpServerTransport;

pub fn formatHttpResponse(
    allocator: Allocator,
    status_code: u16,
    reason: []const u8,
    body: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ status_code, reason, body.len, body },
    );
}
