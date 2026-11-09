const std = @import("std");

pub const KeyValueParam = @import("../../../repository/repository_registry.zig").ConfigParam;
pub const KeyValueEntry = KeyValueParam;

pub const NetworkDriver = enum {
    none,
    ingress_only,
    egress,
    sinkhole,

    pub fn fromString(s: []const u8) ?NetworkDriver {
        if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "isolated")) return .none;
        if (std.mem.eql(u8, s, "ingress_only") or std.mem.eql(u8, s, "ingress")) return .ingress_only;
        if (std.mem.eql(u8, s, "egress")) return .egress;
        if (std.mem.eql(u8, s, "sinkhole") or std.mem.eql(u8, s, "tap")) return .sinkhole;
        return null;
    }

    pub fn asName(self: NetworkDriver) []const u8 {
        return @tagName(self);
    }
};

pub const ProxyStrategy = enum {
    round_robin,
    weighted,
    failover,
    least_latency,
    sticky_host,
    random,

    pub fn fromString(s: []const u8) ?ProxyStrategy {
        if (std.mem.eql(u8, s, "round_robin")) return .round_robin;
        if (std.mem.eql(u8, s, "weighted")) return .weighted;
        if (std.mem.eql(u8, s, "failover")) return .failover;
        if (std.mem.eql(u8, s, "least_latency")) return .least_latency;
        if (std.mem.eql(u8, s, "sticky_host")) return .sticky_host;
        if (std.mem.eql(u8, s, "random")) return .random;
        return null;
    }

    pub fn asName(self: ProxyStrategy) []const u8 {
        return @tagName(self);
    }
};

pub const PolicyDefaultAction = enum {
    deny,
    allow,

    pub fn fromString(s: []const u8) ?PolicyDefaultAction {
        if (std.ascii.eqlIgnoreCase(s, "deny")) return .deny;
        if (std.ascii.eqlIgnoreCase(s, "allow")) return .allow;
        return null;
    }
};

/// Agnostic port range configuration (`PortRangeSpec`).
pub const PortRangeSpec = struct {
    min: u16,
    max: u16,

    pub fn single(port: u16) PortRangeSpec {
        return .{ .min = port, .max = port };
    }

    pub fn contains(self: PortRangeSpec, port: u16) bool {
        return port >= self.min and port <= self.max;
    }
};
pub const PortRangeConfig = PortRangeSpec;

/// Protocol-agnostic L4/L7 ACL allow rule (RFC 3986 normalized).
pub const AllowRuleSpec = struct {
    schemes: []const []const u8 = &.{},
    hosts: []const []const u8 = &.{},
    ports: []const PortRangeSpec = &.{},
    operations: []const []const u8 = &.{},
    resources: []const []const u8 = &.{},
};
pub const AllowRuleConfig = AllowRuleSpec;

/// Declarative L4/L7 security policy (`policy:`).
pub const NetworkPolicySpec = struct {
    default_action: PolicyDefaultAction = .deny,
    block_private_ranges: bool = true,
    block_private_ips: bool = true,
    block_loopback: bool = true,
    block_link_local: bool = true,
    allow_rules: []const AllowRuleSpec = &.{},
};
pub const PolicyConfig = NetworkPolicySpec;

pub const PoolSpec = struct {
    max_connections: usize = 32,
    max_connections_per_host: usize = 8,
    max_pending_acquires: usize = 128,
    acquire_timeout_ms: u64 = 2000,
    alpn: []const []const u8 = &.{},
};
pub const PoolConfig = PoolSpec;

pub const NetworkTimeouts = @import("../../common/timeouts.zig").NetworkTimeouts;
pub const TimeoutsSpec = NetworkTimeouts;
pub const TimeoutsConfig = NetworkTimeouts;

pub const BackpressureSpec = struct {
    bind_tcp_window: bool = true,
    so_rcvbuf_bytes: usize = 262144,
    max_buffer_memory_mb: usize = 64,
};
pub const BackpressureConfig = BackpressureSpec;

pub const RateLimitSpec = struct {
    requests_per_second: f64 = 0.0,
    burst: usize = 0,
    connections_per_second: f64 = 0.0,
    max_bandwidth_mbps: f64 = 0.0,
    max_inflight: usize = 0,
    respect_retry_after: bool = true,
};
pub const RateLimitConfig = RateLimitSpec;

pub const CircuitBreakerSpec = struct {
    failure_threshold: u32 = 3,
    cooldown_ms: u64 = 30000,
    half_open_max_calls: u32 = 2,
    failover_on_status: []const u16 = &.{ 403, 429, 502, 503, 504 },
};
pub const CircuitBreakerConfig = CircuitBreakerSpec;

pub const ProxyEndpointSpec = struct {
    url: []const u8,
    weight: u32 = 1,
    priority: u32 = 1,
    max_inflight: usize = 0,
};
pub const ProxyEndpointConfig = ProxyEndpointSpec;

pub const ProxyPoolSpec = struct {
    strategy: ProxyStrategy = .round_robin,
    strategy_name: ?[]const u8 = null,
    health_check_interval_ms: u64 = 15000,
    circuit_breaker: CircuitBreakerSpec = .{},
    endpoints: []const ProxyEndpointSpec = &.{},

    pub fn effectiveStrategyName(self: ProxyPoolSpec) []const u8 {
        if (self.strategy_name) |sn| return sn;
        return self.strategy.asName();
    }
};
pub const ProxyPoolConfig = ProxyPoolSpec;

pub const DnsSpec = struct {
    servers: []const []const u8 = &.{},
    doh_endpoint: ?[]const u8 = null,
    cache_ttl_sec: u64 = 300,
    min_ttl_sec: u64 = 60,
    max_ttl_sec: u64 = 3600,
    stale_while_revalidate_sec: u64 = 120,
    overrides: []const KeyValueParam = &.{},
};
pub const DnsConfig = DnsSpec;

pub const TlsSpec = struct {
    min_version: []const u8 = "1.2",
    verify_certificates: bool = true,
    pinned_sha256: []const []const u8 = &.{},
    alpn: []const []const u8 = &.{},
};
pub const TlsConfig = TlsSpec;

pub const RedirectRuleSpec = struct {
    from: []const u8,
    to: []const []const u8 = &.{},
    strategy: ProxyStrategy = .round_robin,
    preserve_path: bool = true,

    pub fn effectiveStrategyName(self: RedirectRuleSpec) []const u8 {
        return self.strategy.asName();
    }
};
pub const RedirectRuleConfig = RedirectRuleSpec;

pub const RouteRuleSpec = struct {
    match_host: []const u8,
    proxy_strategy: ?ProxyStrategy = null,
    proxy_strategy_name: ?[]const u8 = null,
    rate_limit: ?RateLimitSpec = null,

    pub fn effectiveProxyStrategyName(self: RouteRuleSpec) ?[]const u8 {
        if (self.proxy_strategy_name) |sn| return sn;
        if (self.proxy_strategy) |ps| return ps.asName();
        return null;
    }
};
pub const RouteRuleConfig = RouteRuleSpec;

pub const CaptureSpec = struct {
    enabled: bool = false,
    format: []const u8 = "pcapng",
    path: ?[]const u8 = null,
    datasource: ?[]const u8 = null,
    channel: []const u8 = "pcap_frames",
    snaplen: u32 = 65535,
    include_tls_keys: bool = false,
    max_file_size_mb: usize = 100,
    max_files: usize = 5,
};
pub const CaptureConfig = CaptureSpec;

/// Canonical configuration specification for a Reactive L4/L7 Virtual Network Adapter (`networks:`).
/// Shared directly between `src/network/` and `src/ast/` (eliminating translation boilerplate).
pub const NetworkSpec = struct {
    id: []const u8,
    driver: NetworkDriver = .none,
    driver_name: ?[]const u8 = null,
    listen: ?[]const u8 = null,
    headers: []const KeyValueParam = &.{},
    policy: NetworkPolicySpec = .{},
    pool: PoolSpec = .{},
    timeouts: TimeoutsSpec = .{},
    backpressure: BackpressureSpec = .{},
    rate_limit: RateLimitSpec = .{},
    proxies: ProxyPoolSpec = .{},
    dns: DnsSpec = .{},
    tls: TlsSpec = .{},
    redirects: []const RedirectRuleSpec = &.{},
    routes: []const RouteRuleSpec = &.{},
    capture: CaptureSpec = .{},
    isolation: []const u8 = "runtime",

    pub fn effectiveDriverName(self: NetworkSpec) []const u8 {
        if (self.driver_name) |dn| return dn;
        return self.driver.asName();
    }
};
pub const AdapterConfig = NetworkSpec;
