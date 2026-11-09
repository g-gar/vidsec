const std = @import("std");
const Allocator = std.mem.Allocator;
pub const uri_mod = @import("../../common/uri.zig");
pub const Uri = uri_mod.Uri;

/// Key-value HTTP/protocol header.
pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
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
    headers: []const HttpHeader = &.{},
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
