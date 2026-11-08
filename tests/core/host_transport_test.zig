const std = @import("std");
const vidsec = @import("vidsec");
const flowdata = @import("flowdata");
const host = flowdata.host;
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
