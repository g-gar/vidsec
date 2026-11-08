const std = @import("std");
const Allocator = std.mem.Allocator;

/// RFC 3986 parsed URI representation (`scheme://host:port/resource`).
pub const Uri = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    resource: []const u8,

    pub fn parse(raw_url: []const u8) ?Uri {
        const scheme_end = std.mem.indexOf(u8, raw_url, "://") orelse return null;
        if (scheme_end == 0) return null;
        const scheme = raw_url[0..scheme_end];
        const rest = raw_url[scheme_end + 3 ..];

        const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..slash_idx];
        const resource = if (slash_idx < rest.len) rest[slash_idx..] else "/";

        const host_port = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
            authority[at + 1 ..]
        else
            authority;

        if (host_port.len == 0) return null;

        var host: []const u8 = host_port;
        var port: u16 = defaultPortForScheme(scheme);

        if (host_port[0] == '[') {
            const close_bracket = std.mem.indexOfScalar(u8, host_port, ']') orelse return null;
            host = host_port[1..close_bracket];
            if (close_bracket + 1 < host_port.len and host_port[close_bracket + 1] == ':') {
                port = std.fmt.parseInt(u16, host_port[close_bracket + 2 ..], 10) catch return null;
            }
        } else if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon_idx| {
            host = host_port[0..colon_idx];
            port = std.fmt.parseInt(u16, host_port[colon_idx + 1 ..], 10) catch return null;
        }

        if (host.len == 0) return null;
        return .{
            .scheme = scheme,
            .host = host,
            .port = port,
            .resource = resource,
        };
    }

    pub fn defaultPortForScheme(scheme: []const u8) u16 {
        if (std.ascii.eqlIgnoreCase(scheme, "https") or
            std.ascii.eqlIgnoreCase(scheme, "wss") or
            std.ascii.eqlIgnoreCase(scheme, "grpcs") or
            std.ascii.eqlIgnoreCase(scheme, "rtmps") or
            std.ascii.eqlIgnoreCase(scheme, "tls") or
            std.ascii.eqlIgnoreCase(scheme, "quic"))
        {
            return 443;
        }
        if (std.ascii.eqlIgnoreCase(scheme, "http") or
            std.ascii.eqlIgnoreCase(scheme, "ws") or
            std.ascii.eqlIgnoreCase(scheme, "grpc"))
        {
            return 80;
        }
        if (std.ascii.eqlIgnoreCase(scheme, "rtmp")) return 1935;
        if (std.ascii.eqlIgnoreCase(scheme, "rtsp")) return 554;
        if (std.ascii.eqlIgnoreCase(scheme, "amqp")) return 5672;
        if (std.ascii.eqlIgnoreCase(scheme, "socks5")) return 1080;
        return 80;
    }
};

/// Domain-agnostic captured exchange record emitted by `MemoryEventSink`.
pub const CapturedExchangeRecord = struct {
    sequence_id: u64,
    timestamp_ms: u64,
    trace_tag: []const u8,
    scheme: []const u8,
    operation: []const u8,
    dst_host: []const u8,
    dst_port: u16,
    resource: []const u8,
    proxy_used: []const u8,
    status_code: u16,
    latency_ms: u64,
    verdict: ExchangeVerdict,
};

/// Low-level adapter telemetry counters.
pub const AdapterMetrics = struct {
    active_connections: usize = 0,
    pending_acquires: usize = 0,
    dns_cache_hits: usize = 0,
    dns_cache_misses: usize = 0,
    circuit_breaker_trips: usize = 0,
    backpressure_stall_ms: u64 = 0,
    allocated_buffer_bytes: usize = 0,
    requests_allowed: usize = 0,
    requests_blocked: usize = 0,
    requests_rate_limited: usize = 0,
    packets_captured: usize = 0,
};

pub const ExchangeVerdict = enum {
    pending,
    allowed,
    blocked,
    captured,
    mocked,
    rate_limited,

    pub fn asText(self: ExchangeVerdict) []const u8 {
        return switch (self) {
            .pending => "PENDING",
            .allowed => "ALLOWED",
            .blocked => "BLOCKED",
            .captured => "CAPTURED",
            .mocked => "MOCKED",
            .rate_limited => "RATE_LIMITED",
        };
    }
};

pub const NetError = error{
    InvalidUri,
    NetworkPolicyDenied,
    NetworkRateLimited,
    NetworkAcquireTimeout,
    NetworkUpstreamError,
    UnsupportedProtocolScheme,
    StreamNotFound,
    OutOfMemory,
};

/// Opaque handle to an active stateful L4/L7 stream (`ws`, `grpc`, `rtmp`, `tcp`, `udp`).
pub const NetStreamId = u64;

/// Normalized response produced by a `ProtocolTransport` or `NetMiddleware`.
pub const NetResult = struct {
    status_code: u16 = 200,
    body: []const u8 = "",
    wire_request: []const u8 = "",
    wire_response: []const u8 = "",
    effective_url: []const u8 = "",
    proxy_used: []const u8 = "",
    latency_ms: u64 = 0,
    retry_after_ms: u64 = 0,
    verdict: ExchangeVerdict = .allowed,
};

/// Mutable context representing a single L4/L7 network exchange flowing through a `MiddlewareChain`.
/// Completely agnostic of pipeline steps or tasks; callers may attach an optional `trace_tag`.
pub const NetExchange = struct {
    allocator: Allocator,
    adapter_id: []const u8,
    trace_tag: []const u8 = "",
    now_ms: u64,

    original_url: []const u8,
    effective_url: []const u8,
    uri: Uri,
    operation: []const u8,
    req_body: []const u8 = "",

    /// Populated by `DnsMiddleware` if active.
    resolved_ip: ?[]const u8 = null,
    /// Populated by `ProxyRouterMiddleware` if a route or proxy pool selects an endpoint.
    selected_proxy_url: []const u8 = "",
    /// Connection & socket parameters forwarded to live transports.
    connect_timeout_ms: u64 = 3000,
    read_timeout_ms: u64 = 10000,
    so_rcvbuf_bytes: usize = 262144,
    /// Mutable metrics pointer owned by the adapter.
    metrics: *AdapterMetrics,
};
