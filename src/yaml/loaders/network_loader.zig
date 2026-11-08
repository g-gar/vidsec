const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml_lib = @import("../lib/mod.zig");
const ast = @import("../../ast/ast.zig");

pub const NetworkLoaderError = error{
    InvalidNetworkDriver,
    InvalidProxyStrategy,
    InvalidPortRange,
} || Allocator.Error;

fn parseBool(s: []const u8, default_val: bool) bool {
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "yes")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "no")) return false;
    return default_val;
}

fn parseStringList(alloc: Allocator, node: yaml_lib.Node) ![]const []const u8 {
    if (node.asSeq()) |seq| {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (seq) |item| {
            if (item.asScalar()) |s| {
                try list.append(alloc, s);
            }
        }
        return try list.toOwnedSlice(alloc);
    } else if (node.asScalar()) |s| {
        const single = try alloc.alloc([]const u8, 1);
        single[0] = s;
        return single;
    }
    return &.{};
}

pub fn parsePortRange(raw: []const u8) NetworkLoaderError!ast.PortRangeSpec {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash_idx| {
        const min_str = std.mem.trim(u8, trimmed[0..dash_idx], " \t");
        const max_str = std.mem.trim(u8, trimmed[dash_idx + 1 ..], " \t");
        const min_p = std.fmt.parseInt(u16, min_str, 10) catch return error.InvalidPortRange;
        const max_p = std.fmt.parseInt(u16, max_str, 10) catch return error.InvalidPortRange;
        if (min_p > max_p) return error.InvalidPortRange;
        return .{ .min = min_p, .max = max_p };
    }
    const port = std.fmt.parseInt(u16, trimmed, 10) catch return error.InvalidPortRange;
    return ast.PortRangeSpec.single(port);
}

fn parsePortList(alloc: Allocator, node: yaml_lib.Node) ![]const ast.PortRangeSpec {
    var list: std.ArrayListUnmanaged(ast.PortRangeSpec) = .empty;
    if (node.asSeq()) |seq| {
        for (seq) |item| {
            if (item.asScalar()) |s| {
                try list.append(alloc, try parsePortRange(s));
            }
        }
    } else if (node.asScalar()) |s| {
        try list.append(alloc, try parsePortRange(s));
    }
    return try list.toOwnedSlice(alloc);
}

fn parseRateLimit(node: yaml_lib.Node) ast.RateLimitSpec {
    var spec = ast.RateLimitSpec{};
    if (node.get("requests_per_second")) |n| {
        if (n.asScalar()) |s| spec.requests_per_second = std.fmt.parseFloat(f64, s) catch 0.0;
    }
    if (node.get("burst")) |n| {
        if (n.asScalar()) |s| spec.burst = std.fmt.parseInt(usize, s, 10) catch 0;
    } else if (node.get("burst_size")) |n| {
        if (n.asScalar()) |s| spec.burst = std.fmt.parseInt(usize, s, 10) catch 0;
    }
    if (node.get("connections_per_second")) |n| {
        if (n.asScalar()) |s| spec.connections_per_second = std.fmt.parseFloat(f64, s) catch 0.0;
    }
    if (node.get("max_bandwidth_mbps")) |n| {
        if (n.asScalar()) |s| spec.max_bandwidth_mbps = std.fmt.parseFloat(f64, s) catch 0.0;
    }
    if (node.get("max_inflight")) |n| {
        if (n.asScalar()) |s| spec.max_inflight = std.fmt.parseInt(usize, s, 10) catch 0;
    }
    if (node.get("respect_retry_after")) |n| {
        if (n.asScalar()) |s| spec.respect_retry_after = parseBool(s, true);
    }
    return spec;
}

fn parsePolicy(alloc: Allocator, net_node: yaml_lib.Node) !ast.NetworkPolicySpec {
    var policy = ast.NetworkPolicySpec{};
    var rules_list: std.ArrayListUnmanaged(ast.AllowRuleSpec) = .empty;

    // Shorthand `allow_hosts: ["api.mangadex.org:443", ...]`
    if (net_node.get("allow_hosts")) |ah_node| {
        if (ah_node.asSeq()) |seq| {
            for (seq) |item| {
                if (item.asScalar()) |host_port| {
                    var host = host_port;
                    var ports: []const ast.PortRangeSpec = &.{};
                    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon_idx| {
                        host = host_port[0..colon_idx];
                        const p_range = try parsePortRange(host_port[colon_idx + 1 ..]);
                        const p_slice = try alloc.alloc(ast.PortRangeSpec, 1);
                        p_slice[0] = p_range;
                        ports = p_slice;
                    }
                    const h_slice = try alloc.alloc([]const u8, 1);
                    h_slice[0] = host;
                    try rules_list.append(alloc, .{
                        .hosts = h_slice,
                        .ports = ports,
                    });
                }
            }
        }
    }

    if (net_node.get("policy")) |pol_node| {
        if (pol_node.get("default_action")) |da| {
            if (da.asScalar()) |s| {
                if (ast.PolicyDefaultAction.fromString(s)) |act| {
                    policy.default_action = act;
                }
            }
        }
        if (pol_node.get("block_private_ranges")) |bpr| {
            if (bpr.asScalar()) |s| {
                const v = parseBool(s, true);
                policy.block_private_ranges = v;
                policy.block_private_ips = v;
                policy.block_loopback = v;
                policy.block_link_local = v;
            }
        }
        if (pol_node.get("block_private_ips")) |bpi| {
            if (bpi.asScalar()) |s| {
                const v = parseBool(s, true);
                policy.block_private_ips = v;
                policy.block_private_ranges = v;
            }
        }
        if (pol_node.get("block_loopback")) |blb| {
            if (blb.asScalar()) |s| policy.block_loopback = parseBool(s, true);
        }
        if (pol_node.get("block_link_local")) |bll| {
            if (bll.asScalar()) |s| policy.block_link_local = parseBool(s, true);
        }
        if (pol_node.get("allow_rules")) |ar_node| {
            if (ar_node.asSeq()) |seq| {
                for (seq) |rule_node| {
                    const schemes = if (rule_node.get("schemes")) |sc|
                        try parseStringList(alloc, sc)
                    else if (rule_node.get("protocol")) |pr|
                        try parseStringList(alloc, pr)
                    else
                        &.{};

                    const hosts = if (rule_node.get("hosts")) |h|
                        try parseStringList(alloc, h)
                    else if (rule_node.get("host")) |h|
                        try parseStringList(alloc, h)
                    else
                        &.{};

                    const ports = if (rule_node.get("ports")) |p|
                        try parsePortList(alloc, p)
                    else if (rule_node.get("port")) |p|
                        try parsePortList(alloc, p)
                    else if (rule_node.get("port_range")) |p|
                        try parsePortList(alloc, p)
                    else
                        &.{};

                    const operations = if (rule_node.get("operations")) |op|
                        try parseStringList(alloc, op)
                    else if (rule_node.get("methods")) |m|
                        try parseStringList(alloc, m)
                    else
                        &.{};

                    const resources = if (rule_node.get("resources")) |res|
                        try parseStringList(alloc, res)
                    else if (rule_node.get("path_prefixes")) |pp|
                        try parseStringList(alloc, pp)
                    else
                        &.{};

                    try rules_list.append(alloc, .{
                        .schemes = schemes,
                        .hosts = hosts,
                        .ports = ports,
                        .operations = operations,
                        .resources = resources,
                    });
                }
            }
        }
    }

    policy.allow_rules = try rules_list.toOwnedSlice(alloc);
    return policy;
}

fn parseProxies(alloc: Allocator, proxies_node: yaml_lib.Node) !ast.ProxyPoolSpec {
    var spec = ast.ProxyPoolSpec{};
    if (proxies_node.get("strategy")) |st| {
        if (st.asScalar()) |s| {
            spec.strategy = ast.ProxyStrategy.fromString(s) orelse return error.InvalidProxyStrategy;
        }
    }
    if (proxies_node.get("health_check_interval_ms")) |hc| {
        if (hc.asScalar()) |s| spec.health_check_interval_ms = std.fmt.parseInt(u64, s, 10) catch 15000;
    }
    if (proxies_node.get("unhealthy_cooldown_ms")) |cd| {
        if (cd.asScalar()) |s| spec.circuit_breaker.cooldown_ms = std.fmt.parseInt(u64, s, 10) catch 30000;
    }
    if (proxies_node.get("circuit_breaker")) |cb| {
        if (cb.get("failure_threshold")) |ft| {
            if (ft.asScalar()) |s| spec.circuit_breaker.failure_threshold = std.fmt.parseInt(u32, s, 10) catch 3;
        }
        if (cb.get("cooldown_ms")) |cd| {
            if (cd.asScalar()) |s| spec.circuit_breaker.cooldown_ms = std.fmt.parseInt(u64, s, 10) catch 30000;
        }
        if (cb.get("half_open_max_calls")) |ho| {
            if (ho.asScalar()) |s| spec.circuit_breaker.half_open_max_calls = std.fmt.parseInt(u32, s, 10) catch 2;
        }
        if (cb.get("failover_on_status")) |fos| {
            if (fos.asSeq()) |seq| {
                var codes: std.ArrayListUnmanaged(u16) = .empty;
                for (seq) |item| {
                    if (item.asScalar()) |s| {
                        if (std.fmt.parseInt(u16, s, 10)) |code| {
                            try codes.append(alloc, code);
                        } else |_| {}
                    }
                }
                spec.circuit_breaker.failover_on_status = try codes.toOwnedSlice(alloc);
            }
        }
    }

    if (proxies_node.get("endpoints")) |ep_node| {
        if (ep_node.asSeq()) |seq| {
            var endpoints: std.ArrayListUnmanaged(ast.ProxyEndpointSpec) = .empty;
            for (seq) |item| {
                if (item.asScalar()) |url_str| {
                    try endpoints.append(alloc, .{ .url = url_str, .weight = 1 });
                } else if (item.asMap() != null) {
                    const url_str = if (item.get("url")) |u| u.asScalar() orelse "" else "";
                    const weight: u32 = if (item.get("weight")) |w|
                        if (w.asScalar()) |ws| std.fmt.parseInt(u32, ws, 10) catch 1 else 1
                    else
                        1;
                    if (url_str.len > 0) {
                        try endpoints.append(alloc, .{ .url = url_str, .weight = weight });
                    }
                }
            }
            spec.endpoints = try endpoints.toOwnedSlice(alloc);
        }
    }
    return spec;
}

pub fn parseStepNetworks(alloc: Allocator, step_node: yaml_lib.Node) ![]const []const u8 {
    if (step_node.get("networks")) |nets_node| {
        return try parseStringList(alloc, nets_node);
    } else if (step_node.get("network")) |net_node| {
        return try parseStringList(alloc, net_node);
    }
    return &.{};
}

pub fn parseNetworkDecl(alloc: Allocator, id: []const u8, net_node: yaml_lib.Node) NetworkLoaderError!ast.NetworkSpec {
    var spec = ast.NetworkSpec{ .id = id };

    if (net_node.get("driver")) |d_node| {
        if (d_node.asScalar()) |d_str| {
            spec.driver = ast.NetworkDriver.fromString(d_str) orelse return error.InvalidNetworkDriver;
        }
    }

    spec.policy = try parsePolicy(alloc, net_node);

    if (net_node.get("pool")) |p_node| {
        if (p_node.get("max_connections")) |n| {
            if (n.asScalar()) |s| spec.pool.max_connections = std.fmt.parseInt(usize, s, 10) catch 32;
        }
        if (p_node.get("max_pending_acquires")) |n| {
            if (n.asScalar()) |s| spec.pool.max_pending_acquires = std.fmt.parseInt(usize, s, 10) catch 128;
        }
        if (p_node.get("acquire_timeout_ms")) |n| {
            if (n.asScalar()) |s| spec.pool.acquire_timeout_ms = std.fmt.parseInt(u64, s, 10) catch 2000;
        }
        if (p_node.get("alpn")) |n| {
            spec.pool.alpn = try parseStringList(alloc, n);
        }
    }

    if (net_node.get("timeouts")) |t_node| {
        if (t_node.get("connect_ms")) |n| {
            if (n.asScalar()) |s| spec.timeouts.connect_ms = std.fmt.parseInt(u64, s, 10) catch 3000;
        }
        if (t_node.get("tls_handshake_ms")) |n| {
            if (n.asScalar()) |s| spec.timeouts.tls_handshake_ms = std.fmt.parseInt(u64, s, 10) catch 3000;
        }
        if (t_node.get("read_idle_ms")) |n| {
            if (n.asScalar()) |s| spec.timeouts.read_idle_ms = std.fmt.parseInt(u64, s, 10) catch 10000;
        }
        if (t_node.get("write_idle_ms")) |n| {
            if (n.asScalar()) |s| spec.timeouts.write_idle_ms = std.fmt.parseInt(u64, s, 10) catch 5000;
        }
    } else if (net_node.get("timeout_ms")) |tm| {
        if (tm.asScalar()) |s| {
            const ms = std.fmt.parseInt(u64, s, 10) catch 5000;
            spec.timeouts.connect_ms = ms;
            spec.timeouts.read_idle_ms = ms;
        }
    }

    if (net_node.get("backpressure")) |bp_node| {
        if (bp_node.get("bind_tcp_window")) |n| {
            if (n.asScalar()) |s| spec.backpressure.bind_tcp_window = parseBool(s, true);
        }
        if (bp_node.get("so_rcvbuf_bytes")) |n| {
            if (n.asScalar()) |s| spec.backpressure.so_rcvbuf_bytes = std.fmt.parseInt(usize, s, 10) catch 262144;
        }
        if (bp_node.get("max_buffer_memory_mb")) |n| {
            if (n.asScalar()) |s| spec.backpressure.max_buffer_memory_mb = std.fmt.parseInt(usize, s, 10) catch 64;
        }
    }

    if (net_node.get("rate_limit")) |rl_node| {
        spec.rate_limit = parseRateLimit(rl_node);
    }

    if (net_node.get("proxies")) |pr_node| {
        spec.proxies = try parseProxies(alloc, pr_node);
    }

    if (net_node.get("dns")) |dns_node| {
        if (dns_node.get("doh_endpoint")) |n| spec.dns.doh_endpoint = n.asScalar();
        if (dns_node.get("min_ttl_sec")) |n| {
            if (n.asScalar()) |s| spec.dns.min_ttl_sec = std.fmt.parseInt(u64, s, 10) catch 60;
        }
        if (dns_node.get("max_ttl_sec")) |n| {
            if (n.asScalar()) |s| spec.dns.max_ttl_sec = std.fmt.parseInt(u64, s, 10) catch 3600;
        }
        if (dns_node.get("stale_while_revalidate_sec")) |n| {
            if (n.asScalar()) |s| spec.dns.stale_while_revalidate_sec = std.fmt.parseInt(u64, s, 10) catch 120;
        }
        if (dns_node.get("overrides")) |ov_node| {
            if (ov_node.asMap()) |entries| {
                var ov_list: std.ArrayListUnmanaged(std.meta.Elem(@TypeOf(spec.dns.overrides))) = .empty;
                for (entries) |entry| {
                    if (entry.value.asScalar()) |ip_str| {
                        try ov_list.append(alloc, .{ .key = entry.key, .value = ip_str });
                    }
                }
                spec.dns.overrides = try ov_list.toOwnedSlice(alloc);
            }
        }
    }

    if (net_node.get("tls")) |tls_node| {
        if (tls_node.get("verify_certificates")) |n| {
            if (n.asScalar()) |s| spec.tls.verify_certificates = parseBool(s, true);
        }
        if (tls_node.get("pinned_sha256")) |n| {
            spec.tls.pinned_sha256 = try parseStringList(alloc, n);
        }
    }

    if (net_node.get("redirects")) |red_node| {
        if (red_node.asSeq()) |seq| {
            var red_list: std.ArrayListUnmanaged(ast.RedirectRuleSpec) = .empty;
            for (seq) |item| {
                const from_str = if (item.get("from")) |f| f.asScalar() orelse "" else "";
                const to_list = if (item.get("to")) |t| try parseStringList(alloc, t) else &.{};
                const strat = if (item.get("strategy")) |st|
                    if (st.asScalar()) |s| ast.ProxyStrategy.fromString(s) orelse .round_robin else .round_robin
                else
                    .round_robin;
                if (from_str.len > 0 and to_list.len > 0) {
                    try red_list.append(alloc, .{
                        .from = from_str,
                        .to = to_list,
                        .strategy = strat,
                    });
                }
            }
            spec.redirects = try red_list.toOwnedSlice(alloc);
        }
    }

    if (net_node.get("routes")) |rt_node| {
        if (rt_node.asSeq()) |seq| {
            var rt_list: std.ArrayListUnmanaged(ast.RouteRuleSpec) = .empty;
            for (seq) |item| {
                const match_host = if (item.get("match_host")) |mh| mh.asScalar() orelse "" else "";
                if (match_host.len > 0) {
                    const proxy_strat: ?ast.ProxyStrategy = if (item.get("proxy_strategy")) |ps|
                        if (ps.asScalar()) |s| ast.ProxyStrategy.fromString(s) else null
                    else
                        null;
                    const rl: ?ast.RateLimitSpec = if (item.get("rate_limit")) |rln| parseRateLimit(rln) else null;
                    try rt_list.append(alloc, .{
                        .match_host = match_host,
                        .proxy_strategy = proxy_strat,
                        .rate_limit = rl,
                    });
                }
            }
            spec.routes = try rt_list.toOwnedSlice(alloc);
        }
    }

    if (net_node.get("capture")) |cap_node| {
        if (cap_node.get("enabled")) |n| {
            if (n.asScalar()) |s| spec.capture.enabled = parseBool(s, false);
        }
        if (cap_node.get("format")) |n| {
            if (n.asScalar()) |s| spec.capture.format = s;
        }
        if (cap_node.get("datasource")) |n| {
            spec.capture.datasource = n.asScalar();
        }
        if (cap_node.get("channel")) |n| {
            if (n.asScalar()) |s| spec.capture.channel = s;
        }
        if (cap_node.get("path")) |n| {
            spec.capture.path = n.asScalar();
        }
        if (cap_node.get("snaplen")) |n| {
            if (n.asScalar()) |s| spec.capture.snaplen = std.fmt.parseInt(u32, s, 10) catch 65535;
        }
        if (cap_node.get("include_tls_keys")) |n| {
            if (n.asScalar()) |s| spec.capture.include_tls_keys = parseBool(s, false);
        }
        if (cap_node.get("ring_buffer")) |rb_node| {
            if (rb_node.get("max_file_size_mb")) |n| {
                if (n.asScalar()) |s| spec.capture.max_file_size_mb = std.fmt.parseInt(usize, s, 10) catch 100;
            }
            if (rb_node.get("max_files")) |n| {
                if (n.asScalar()) |s| spec.capture.max_files = std.fmt.parseInt(usize, s, 10) catch 5;
            }
        }
    }

    if (net_node.get("emulate_responses")) |em_node| {
        if (em_node.asScalar()) |s| spec.emulate_responses = parseBool(s, false);
    }
    if (net_node.get("isolation")) |iso_node| {
        if (iso_node.asScalar()) |s| spec.isolation = s;
    }

    return spec;
}
