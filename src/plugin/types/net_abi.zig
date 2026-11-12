const Slice_ABI = @import("slice_abi.zig").Slice_ABI;
const NamedField_ABI = @import("named_field_abi.zig").NamedField_ABI;
const HostError_ABI = @import("host_error_abi.zig").HostError_ABI;

/// Protocol-agnostic network request descriptor across the C-ABI boundary.
/// Normalized around RFC 3986 URIs (`url`), `operation` (e.g. "GET", "POST", "PLAY", "CONNECT"),
/// and optional metadata headers/body.
pub const NetRequest_ABI = extern struct {
    /// Target URI (e.g. "https://api.example.com/v1/resource" or "rtmps://ingest.example.com/live/ch1").
    url: Slice_ABI,
    /// Normalized operation/verb (e.g. "GET", "POST", "HANDSHAKE", "PLAY", "PUBLISH", "CONNECT").
    operation: Slice_ABI = Slice_ABI.fromSlice("GET"),
    /// Optional protocol metadata / HTTP headers.
    headers_ptr: ?[*]const NamedField_ABI = null,
    headers_len: usize = 0,
    /// Optional request payload bytes.
    body: Slice_ABI = Slice_ABI.fromSlice(""),
    /// Optional explicit adapter selector for multi-homed steps (empty = primary step network).
    network_id: Slice_ABI = Slice_ABI.fromSlice(""),
};

/// Network response populated by the Host's Virtual Network Adapter.
pub const NetResponse_ABI = extern struct {
    /// Protocol status code (e.g. 200, 429, 403 for HTTP/RTSP, or 0 for raw L4 streams).
    status_code: u16 = 0,
    /// Response payload bytes (allocated in the step's scoped arena).
    body: Slice_ABI = Slice_ABI.fromSlice(""),
    /// Effective URL after applying adapter `redirects:` rules.
    effective_url: Slice_ABI = Slice_ABI.fromSlice(""),
    /// Proxy endpoint selected by the adapter's `proxies:` pool (empty if direct).
    proxy_used: Slice_ABI = Slice_ABI.fromSlice(""),
    /// Round-trip latency measured in milliseconds.
    latency_ms: u64 = 0,
};

/// Opaque handle to a stateful bidirectional network stream (`ws`, `rtmp`, `grpc`, `tcp`, `udp`, `tls`).
pub const NetStreamHandle_ABI = u64;

/// Standalone C-ABI network request callback (for Black Box tasks via `ExecutionOptions_ABI`).
pub const NetRequestFn_ABI = *const fn (
    opaque_net_ctx: ?*anyopaque,
    req: *const NetRequest_ABI,
    out_resp: *NetResponse_ABI,
) callconv(.c) HostError_ABI;
