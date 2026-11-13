const std = @import("std");
const vidsec = @import("vidsec");
const flowdata = @import("flowdata");
const host = vidsec.host;
const abi = vidsec.abi;
const pipeline = vidsec.pipeline;

test "Host Transport VTable: Assert Implements on CLI, HTTP and gRPC" {
    host.HostTransport.assertImplements(host.CliTransport);
    host.HostTransport.assertImplements(host.HttpServerTransport);
    host.HostTransport.assertImplements(host.GrpcTransport);
}

test "HostDispatcher & CliTransport: version, help, health and format handling" {
    const alloc = std.testing.allocator;

    var dispatcher = host.HostDispatcher.init(alloc, .{
        .app_name = "test_engine",
        .description = "Test Flowdata Engine",
        .version = "1.2.3",
    });
    defer dispatcher.deinit();

    // 1. Version command (text format)
    const v_text = try dispatcher.handle(.{
        .command = .version,
        .format = .text,
        .options = .{ .pipeline_yaml_path = "" },
    });
    try std.testing.expectEqualStrings("test_engine 1.2.3\n", v_text.message);

    // 2. Version command (json format)
    const v_json = try dispatcher.handle(.{
        .command = .version,
        .format = .json,
        .options = .{ .pipeline_yaml_path = "" },
    });
    try std.testing.expectEqualStrings("{\"app\":\"test_engine\",\"version\":\"1.2.3\"}\n", v_json.message);

    // 3. Health command
    const health_res = try dispatcher.handle(.{
        .command = .health,
        .format = .json,
        .options = .{ .pipeline_yaml_path = "" },
    });
    try std.testing.expect(std.mem.indexOf(u8, health_res.output_bytes, "\"status\":\"healthy\"") != null);

    // 4. Help command
    const help_res = try dispatcher.handle(.{
        .command = .help,
        .format = .text,
        .options = .{ .pipeline_yaml_path = "" },
    });
    try std.testing.expect(std.mem.indexOf(u8, help_res.message, "Usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_res.message, "test_engine validate") != null);
}

test "HttpServerTransport: REST API routing, status codes, and execution" {
    const alloc = std.testing.allocator;

    var dispatcher = host.HostDispatcher.init(alloc, .{
        .app_name = "vidsec_service",
        .description = "Vidsec REST Daemon",
        .version = "2.0.0",
        .driver_initializer = &vidsec.extensions.datasources.registerDefaultDrivers,
        .extensions = &.{
            vidsec.extensions.inbound_cli.extension,
        },
    });
    defer dispatcher.deinit();

    var http_server = host.HttpServerTransport.init(alloc, "127.0.0.1", 8080, "apps/vidsec/configs/pipeline.yaml");

    // 1. GET /v1/health -> 200 OK
    const raw_get_health = "GET /v1/health HTTP/1.1\r\nHost: localhost:8080\r\n\r\n";
    const res_health = try http_server.handleHttpRequest(alloc, raw_get_health, &dispatcher, &host.HostDispatcher.dispatchOpaque);
    defer alloc.free(res_health);

    try std.testing.expect(std.mem.startsWith(u8, res_health, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, res_health, "\"status\":\"healthy\"") != null);

    // 2. GET /v1/version -> 200 OK
    const raw_get_version = "GET /v1/version HTTP/1.1\r\nHost: localhost:8080\r\n\r\n";
    const res_version = try http_server.handleHttpRequest(alloc, raw_get_version, &dispatcher, &host.HostDispatcher.dispatchOpaque);
    defer alloc.free(res_version);

    try std.testing.expect(std.mem.startsWith(u8, res_version, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, res_version, "\"version\":\"2.0.0\"") != null);

    // 3. POST /v1/validate -> 200 OK with pre-flight check
    const raw_post_validate = "POST /v1/validate HTTP/1.1\r\nHost: localhost:8080\r\nX-Pipeline-Path: apps/vidsec/configs/pipeline.yaml\r\nX-Skip-So: true\r\n\r\n";
    const res_validate = try http_server.handleHttpRequest(alloc, raw_post_validate, &dispatcher, &host.HostDispatcher.dispatchOpaque);
    defer alloc.free(res_validate);

    try std.testing.expect(std.mem.startsWith(u8, res_validate, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, res_validate, "Pre-flight validation passed") != null);

    // 4. POST /unknown -> 404 Not Found
    const raw_post_unknown = "POST /v1/nonexistent HTTP/1.1\r\nHost: localhost:8080\r\n\r\n";
    const res_unknown = try http_server.handleHttpRequest(alloc, raw_post_unknown, &dispatcher, &host.HostDispatcher.dispatchOpaque);
    defer alloc.free(res_unknown);

    try std.testing.expect(std.mem.startsWith(u8, res_unknown, "HTTP/1.1 404 Not Found"));
}

test "HttpServerTransport: POST /v1/jobs JobEnvelope unwrapping and validation" {
    const alloc = std.testing.allocator;

    const MockDispatcher = struct {
        last_payload: []const u8 = "",
        call_count: usize = 0,
        alloc: std.mem.Allocator,

        fn dispatch(ctx: *anyopaque, req: host.InvocationRequest) anyerror!host.InvocationResponse {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.call_count += 1;
            try std.testing.expectEqual(host.InvocationCommand.run, req.command);
            switch (req.input) {
                .job_json => |bytes| {
                    if (self.last_payload.len > 0) self.alloc.free(self.last_payload);
                    self.last_payload = try self.alloc.dupe(u8, bytes);
                },
                else => return error.ExpectedJobJson,
            }
            return .{
                .status = .ok,
                .exit_code = 0,
                .output_bytes = "{\"status\":\"ok\"}\n",
            };
        }
    };

    var mock = MockDispatcher{ .alloc = alloc };
    defer if (mock.last_payload.len > 0) alloc.free(mock.last_payload);

    var http_server = host.HttpServerTransport.init(alloc, "127.0.0.1", 8080, "apps/mangadex/configs/pipeline.yaml");

    // 1. Empty body -> 400
    const res_empty = try http_server.handleHttpRequest(alloc, "POST /v1/jobs HTTP/1.1\r\nHost: localhost:8080\r\n\r\n", &mock, &MockDispatcher.dispatch);
    defer alloc.free(res_empty);
    try std.testing.expect(std.mem.startsWith(u8, res_empty, "HTTP/1.1 400 Bad Request"));
    try std.testing.expect(std.mem.indexOf(u8, res_empty, "empty_job_envelope") != null);

    // 2. Missing payload -> 400
    const res_missing = try http_server.handleHttpRequest(
        alloc,
        "POST /v1/jobs HTTP/1.1\r\nHost: localhost:8080\r\n\r\n{\"id\":\"job_1\"}",
        &mock,
        &MockDispatcher.dispatch,
    );
    defer alloc.free(res_missing);
    try std.testing.expect(std.mem.startsWith(u8, res_missing, "HTTP/1.1 400 Bad Request"));
    try std.testing.expect(std.mem.indexOf(u8, res_missing, "missing_job_payload") != null);

    // 3. ARCH-019 payload_raw JSON object -> 200 OK with serialized object
    const res_raw = try http_server.handleHttpRequest(
        alloc,
        "POST /v1/jobs HTTP/1.1\r\nHost: localhost:8080\r\n\r\n{\"id\":\"job_2\",\"payload_raw\":{\"series_id\":\"abc\"}}",
        &mock,
        &MockDispatcher.dispatch,
    );
    defer alloc.free(res_raw);
    try std.testing.expect(std.mem.startsWith(u8, res_raw, "HTTP/1.1 200 OK"));
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
    try std.testing.expectEqualStrings("{\"series_id\":\"abc\"}", mock.last_payload);

    // 4. send_mangadex_job.sh payload JSON string -> 200 OK with unescaped string
    const res_str = try http_server.handleHttpRequest(
        alloc,
        "POST /v1/jobs HTTP/1.1\r\nHost: localhost:8080\r\n\r\n{\"id\":\"job_3\",\"payload\":\"{\\\"series_id\\\":\\\"xyz\\\"}\"}",
        &mock,
        &MockDispatcher.dispatch,
    );
    defer alloc.free(res_str);
    try std.testing.expect(std.mem.startsWith(u8, res_str, "HTTP/1.1 200 OK"));
    try std.testing.expectEqual(@as(usize, 2), mock.call_count);
    try std.testing.expectEqualStrings("{\"series_id\":\"xyz\"}", mock.last_payload);
}

test "GrpcTransport: Binary Framing and PipelineService Dispatch" {
    const alloc = std.testing.allocator;

    // 1. Test 5-byte gRPC framing encode and decode
    const test_payload = "{\"pipeline\":\"pipeline.yaml\",\"status\":\"ok\"}";
    const frame = try host.GrpcTransport.encodeGrpcFrame(alloc, test_payload);
    defer alloc.free(frame);

    try std.testing.expectEqual(@as(usize, 5 + test_payload.len), frame.len);
    try std.testing.expectEqual(@as(u8, 0x00), frame[0]); // Uncompressed
    const frame_len = std.mem.readInt(u32, frame[1..5], .big);
    try std.testing.expectEqual(@as(u32, @intCast(test_payload.len)), frame_len);

    const decoded = try host.GrpcTransport.decodeGrpcFrame(frame);
    try std.testing.expectEqualStrings(test_payload, decoded);

    // 2. Test gRPC Service Invocations
    var dispatcher = host.HostDispatcher.init(alloc, .{
        .app_name = "vidsec_grpc",
        .version = "2.0.0",
        .driver_initializer = &vidsec.extensions.datasources.registerDefaultDrivers,
        .extensions = &.{
            vidsec.extensions.inbound_cli.extension,
        },
    });
    defer dispatcher.deinit();

    var grpc_service = host.GrpcTransport.init(alloc, "127.0.0.1", 50051, "apps/vidsec/configs/pipeline.yaml");

    // Call /flowdata.v2.PipelineService/Health
    const req_frame = try host.GrpcTransport.encodeGrpcFrame(alloc, "{}");
    defer alloc.free(req_frame);

    const res_frame = try grpc_service.handleGrpcCall(
        alloc,
        "/flowdata.v2.PipelineService/Health",
        req_frame,
        &dispatcher,
        &host.HostDispatcher.dispatchOpaque,
    );
    defer alloc.free(res_frame);

    const res_body = try host.GrpcTransport.decodeGrpcFrame(res_frame);
    try std.testing.expect(std.mem.indexOf(u8, res_body, "\"status\":\"healthy\"") != null);
}

test "HostApp: Declarative Entrypoint Execution" {
    const alloc = std.testing.allocator;

    const config = host.AppConfig{
        .app_name = "vidsec_cli_test",
        .description = "CLI Test App",
        .version = "2.0.0",
        .driver_initializer = &vidsec.extensions.datasources.registerDefaultDrivers,
        .extensions = &.{
            vidsec.extensions.inbound_cli.extension,
        },
    };

    // 1. Invocation with `--version` returns 0
    const rc_ver = try host.HostApp.runArgs(alloc, &[_][]const u8{ "vidsec", "--version" }, config);
    try std.testing.expectEqual(@as(u8, 0), rc_ver);

    // 2. Invocation with `help` returns 0
    const rc_help = try host.HostApp.runArgs(alloc, &[_][]const u8{ "vidsec", "help" }, config);
    try std.testing.expectEqual(@as(u8, 0), rc_help);

    // 3. Invocation with `validate` returns 0
    const rc_val = try host.HostApp.runArgs(
        alloc,
        &[_][]const u8{ "vidsec", "validate", "--pipeline", "apps/vidsec/configs/pipeline.yaml", "--skip-so" },
        config,
    );
    try std.testing.expectEqual(@as(u8, 0), rc_val);
}

test "Inbound: Dynamic Inbound Transport Registration and Custom Command Dispatch" {
    const alloc = std.testing.allocator;

    // 1. Custom Command registration on InboundDispatcher
    var dispatcher = host.InboundDispatcher.init(alloc, .{
        .app_name = "test_app",
        .version = "1.0.0",
    });
    defer dispatcher.deinit();

    const DummyCustom = struct {
        fn handleCmd(_: ?*anyopaque, a: std.mem.Allocator, req: host.InvocationRequest) anyerror!host.InvocationResponse {
            const out = try std.fmt.allocPrint(a, "Executed custom {s}", .{req.custom_command_name});
            return .{
                .status = .ok,
                .message = out,
                .output_bytes = out,
                .exit_code = 0,
            };
        }
    };

    try dispatcher.registerCommand("my-cmd", .{
        .ptr = null,
        .handler = &DummyCustom.handleCmd,
    });

    const res = try dispatcher.handle(.{
        .command = .custom,
        .custom_command_name = "my-cmd",
        .options = .{ .pipeline_yaml_path = "" },
    });
    try std.testing.expectEqual(host.InvocationStatus.ok, res.status);
    try std.testing.expectEqualStrings("Executed custom my-cmd", res.message);

    // 2. Custom Inbound Transport registration on InboundRegistry
    const MockInboundTransport = struct {
        invoked: bool = false,

        pub fn inboundTransport(self: *@This()) host.InboundTransport {
            const Self = @This();
            const Trampoline = struct {
                fn doName(_: *const anyopaque) []const u8 {
                    return "mock_inbound";
                }
                fn doServe(ctx: *anyopaque, _: host.DispatcherPtr, _: host.DispatchFn) anyerror!u8 {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    s.invoked = true;
                    return 42;
                }
                fn doDeinit(ctx: *anyopaque, a: std.mem.Allocator) void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    a.destroy(s);
                }
                const vtable = host.InboundTransport.VTable{
                    .name = &doName,
                    .serve = &doServe,
                    .deinit = &doDeinit,
                };
            };
            return .{ .ptr = self, .vtable = &Trampoline.vtable };
        }

        pub fn createDaemon(a: std.mem.Allocator, _: host.InboundTransportConfig) anyerror!host.InboundTransport {
            const s = try a.create(@This());
            s.* = .{ .invoked = false };
            return s.inboundTransport();
        }
    };

    var inbound_reg = host.InboundRegistry.init(alloc);
    defer inbound_reg.deinit();

    try inbound_reg.register("mock_inbound", &MockInboundTransport.createDaemon);

    var custom_transport = try inbound_reg.create("mock_inbound", .{
        .listen_address = "custom://socket",
    });
    defer custom_transport.deinit(alloc);

    try std.testing.expectEqualStrings("mock_inbound", custom_transport.name());
    const rc = try custom_transport.serve(&dispatcher, &host.InboundDispatcher.dispatchOpaque);
    try std.testing.expectEqual(@as(u8, 42), rc);
}

test "NetworkTimeouts: Unified Inbound and Outbound Configuration" {
    const NetworkTimeouts = flowdata.transport.NetworkTimeouts;

    // 1. Common NetworkTimeouts defaults
    const default_timeouts = NetworkTimeouts{};
    try std.testing.expectEqual(@as(u64, 3_000), default_timeouts.connect_ms);
    try std.testing.expectEqual(@as(u64, 10_000), default_timeouts.read_idle_ms);
    try std.testing.expectEqual(@as(u64, 5_000), default_timeouts.write_idle_ms);
    try std.testing.expectEqual(@as(u64, 3_000), default_timeouts.connectTimeoutMs());
    try std.testing.expectEqual(@as(u64, 10_000), default_timeouts.readTimeoutMs());

    // 2. Outbound AdapterConfig uses unified NetworkTimeouts
    const out_cfg = flowdata.transport.outbound.contracts.AdapterConfig{
        .id = "test_egress",
        .driver = .egress,
        .timeouts = .{
            .connect_ms = 4_500,
            .read_idle_ms = 12_000,
        },
    };
    try std.testing.expectEqual(@as(u64, 4_500), out_cfg.timeouts.connect_ms);
    try std.testing.expectEqual(@as(u64, 12_000), out_cfg.timeouts.read_idle_ms);

    // 3. Inbound ServeConfig & InboundTransportConfig use unified NetworkTimeouts
    const serve_cfg = flowdata.transport.inbound.ServeConfig{
        .timeouts = .{
            .connect_ms = 1_500,
            .read_idle_ms = 8_000,
        },
    };
    try std.testing.expectEqual(@as(u64, 1_500), serve_cfg.timeouts.connect_ms);
    try std.testing.expectEqual(@as(u64, 8_000), serve_cfg.timeouts.read_idle_ms);

    const in_trans_cfg = flowdata.transport.inbound.InboundTransportConfig{
        .timeouts = serve_cfg.timeouts,
    };
    try std.testing.expectEqual(@as(u64, 1_500), in_trans_cfg.timeouts.connect_ms);
}
