const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("../abi/mod.zig");
const ast_mod = @import("../ast/ast.zig");
const dataflow = @import("../dataflow/mod.zig");
const repository_mod = @import("../repository/mod.zig");
const network_mod = @import("../network/mod.zig");
const runner_mod = @import("runner.zig");

pub const NetworkRegistry = network_mod.NetworkRegistry;
pub const NetworkAdapter = network_mod.NetworkAdapter;
pub const CapturedExchangeRecord = network_mod.CapturedExchangeRecord;
pub const NetStreamId = network_mod.NetStreamId;
pub const RepositoryRegistry = repository_mod.RepositoryRegistry;
pub const PayloadHandle = dataflow.PayloadHandle;

/// Structured relational row emitted to the `from: network.captured_events` dataflow channel
/// (`components.schemas.network_event`).
/// Belongs to the Engine layer because it binds pure network telemetry (`CapturedExchangeRecord`)
/// to pipeline execution context (`step_id`).
pub const NetworkEvent = struct {
    event_id: i64,
    step_id: []const u8,
    timestamp: i64,
    protocol: []const u8,
    http_method: []const u8,
    dst_host: []const u8,
    dst_port: i64,
    uri_path: []const u8,
    proxy_used: []const u8,
    status_code: i64,
    latency_ms: i64,
    verdict: []const u8,
};

pub const ActiveStreamEntry = struct {
    adapter: NetworkAdapter,
    stream_id: NetStreamId,
};

/// Engine-level coordinator bridging `PipelineAST` (`networks:` + `runtime.default_network`),
/// step-scoped C-ABI network operations (`net_request`, `net_connect`, `net_send`, `net_recv`, `net_close`),
/// `network.captured_events` dataflow materialization, and `.pcapng` forensic persistence to datasources and disk.
pub const EngineNetworkController = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    owned_registry: ?NetworkRegistry = null,
    active_registry: *NetworkRegistry = undefined,
    default_network_id: []const u8 = "isolated",
    network_specs: []const ast_mod.NetworkSpec = &.{},
    stream_table: std.AutoHashMapUnmanaged(abi.NetStreamHandle_ABI, ActiveStreamEntry) = .empty,
    next_abi_stream_handle: abi.NetStreamHandle_ABI = 1,

    pub fn init(
        allocator: Allocator,
        ast: ast_mod.PipelineAST,
        external_registry: ?*NetworkRegistry,
    ) !EngineNetworkController {
        var self = EngineNetworkController{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .default_network_id = ast.runtime.default_network,
            .network_specs = ast.networks,
        };
        errdefer self.deinit();

        if (external_registry) |ext| {
            self.active_registry = ext;
        } else {
            self.owned_registry = NetworkRegistry.init(allocator);
            self.active_registry = &self.owned_registry.?;
        }

        for (ast.networks) |net_spec| {
            _ = try self.active_registry.resolveOrCreate(net_spec);
        }
        _ = try self.active_registry.ensureBuiltinIsolated(ast.runtime.default_network);

        return self;
    }

    pub fn deinit(self: *EngineNetworkController) void {
        var it = self.stream_table.valueIterator();
        while (it.next()) |entry| {
            entry.adapter.streamClose(entry.stream_id);
        }
        self.stream_table.deinit(self.allocator);
        if (self.owned_registry) |*reg| {
            reg.deinit();
        }
        self.arena.deinit();
    }

    /// Resolves the primary `NetworkAdapter` bound to a pipeline task step.
    pub fn resolveStepAdapter(self: *EngineNetworkController, task_spec: ast_mod.TaskStepSpec) !NetworkAdapter {
        const net_id = task_spec.primaryNetwork(self.default_network_id);
        return self.active_registry.get(net_id) orelse try self.active_registry.ensureBuiltinIsolated(net_id);
    }

    /// Resolves either the explicit `network_id` requested in `NetRequest_ABI` or falls back to `primary_adapter`.
    pub fn resolveRequestAdapter(
        self: *const EngineNetworkController,
        primary_adapter: ?NetworkAdapter,
        explicit_network_id: []const u8,
    ) ResultAdapter {
        if (explicit_network_id.len > 0) {
            if (self.active_registry.get(explicit_network_id)) |ad| {
                return .{ .adapter = ad };
            }
            return .not_found;
        }
        if (primary_adapter) |ad| {
            return .{ .adapter = ad };
        }
        return .denied;
    }

    pub const ResultAdapter = union(enum) {
        adapter: NetworkAdapter,
        not_found,
        denied,
    };

    pub fn formatTraceTag(self: *EngineNetworkController, step_id: []const u8, task_name: []const u8) []const u8 {
        if (step_id.len == 0 and task_name.len == 0) return "";
        return std.fmt.allocPrint(
            self.arena.allocator(),
            "step_id={s} task={s}",
            .{ step_id, task_name },
        ) catch "";
    }

    /// Executes a transactional `net_request` across the C-ABI boundary.
    pub fn executeRequest(
        self: *EngineNetworkController,
        step_id: []const u8,
        task_name: []const u8,
        primary_adapter: ?NetworkAdapter,
        req_ptr: *const abi.NetRequest_ABI,
        out_resp: *abi.NetResponse_ABI,
    ) abi.HostError_ABI {
        const req = req_ptr.*;
        const target = switch (self.resolveRequestAdapter(primary_adapter, req.network_id.asSlice())) {
            .adapter => |a| a,
            .not_found => return .not_found,
            .denied => return .network_policy_denied,
        };

        const trace_tag = self.formatTraceTag(step_id, task_name);
        const res = target.execute(
            req.url.asSlice(),
            req.operation.asSlice(),
            req.body.asSlice(),
            trace_tag,
        ) catch |err| return mapNetErrorToHostError(err);

        out_resp.* = .{
            .status_code = res.status_code,
            .body = abi.Slice_ABI.fromSlice(res.body),
            .effective_url = abi.Slice_ABI.fromSlice(res.effective_url),
            .proxy_used = abi.Slice_ABI.fromSlice(res.proxy_used),
            .latency_ms = res.latency_ms,
        };
        return .ok;
    }

    /// Opens a stateful stream (`net_connect`) across the C-ABI boundary (`ws`, `rtmp`, `grpc`, `tcp`, `udp`, `tls`).
    pub fn connectStream(
        self: *EngineNetworkController,
        step_id: []const u8,
        task_name: []const u8,
        primary_adapter: ?NetworkAdapter,
        req_ptr: *const abi.NetRequest_ABI,
        out_handle: *abi.NetStreamHandle_ABI,
    ) abi.HostError_ABI {
        const req = req_ptr.*;
        const target = switch (self.resolveRequestAdapter(primary_adapter, req.network_id.asSlice())) {
            .adapter => |a| a,
            .not_found => return .not_found,
            .denied => return .network_policy_denied,
        };

        const trace_tag = self.formatTraceTag(step_id, task_name);
        const adapter_stream_id = target.connectStream(
            req.url.asSlice(),
            req.operation.asSlice(),
            trace_tag,
        ) catch |err| return mapNetErrorToHostError(err);

        const abi_handle = self.next_abi_stream_handle;
        self.next_abi_stream_handle += 1;

        self.stream_table.put(self.allocator, abi_handle, .{
            .adapter = target,
            .stream_id = adapter_stream_id,
        }) catch return .out_of_memory;

        out_handle.* = abi_handle;
        return .ok;
    }

    /// Sends bytes over an active stream (`net_send`).
    pub fn sendStream(
        self: *EngineNetworkController,
        handle: abi.NetStreamHandle_ABI,
        src_ptr: [*]const u8,
        len: usize,
    ) abi.HostError_ABI {
        const entry = self.stream_table.get(handle) orelse return .not_found;
        const payload = if (len > 0) src_ptr[0..len] else &.{};
        _ = entry.adapter.streamSend(entry.stream_id, payload) catch |err| return mapNetErrorToHostError(err);
        return .ok;
    }

    /// Receives bytes from an active stream (`net_recv`).
    pub fn recvStream(
        self: *EngineNetworkController,
        handle: abi.NetStreamHandle_ABI,
        dest_ptr: [*]u8,
        max_len: usize,
        out_read_len: *usize,
    ) abi.HostError_ABI {
        const entry = self.stream_table.get(handle) orelse return .not_found;
        if (max_len == 0) {
            out_read_len.* = 0;
            return .ok;
        }
        const n = entry.adapter.streamRecv(entry.stream_id, dest_ptr[0..max_len]) catch |err| return mapNetErrorToHostError(err);
        out_read_len.* = n;
        if (n == 0) return .end_of_stream;
        return .ok;
    }

    /// Closes an active stream (`net_close`).
    pub fn closeStream(
        self: *EngineNetworkController,
        handle: abi.NetStreamHandle_ABI,
    ) abi.HostError_ABI {
        const kv = self.stream_table.fetchRemove(handle) orelse return .not_found;
        kv.value.adapter.streamClose(kv.value.stream_id);
        return .ok;
    }

    /// Materializes `NetworkEvent` rows from the adapter's domain-agnostic `CapturedExchangeRecord` slice
    /// for a specific pipeline `step_id` (`from: network.captured_events`).
    pub fn collectStepEvents(
        self: *EngineNetworkController,
        step_id: []const u8,
        adapter: NetworkAdapter,
        records_before: usize,
    ) ![]const NetworkEvent {
        const all_records = adapter.capturedRecordsSlice();
        if (records_before >= all_records.len) return &.{};

        const slice = all_records[records_before..];
        const a = self.arena.allocator();
        const events = try a.alloc(NetworkEvent, slice.len);
        for (slice, 0..) |rec, idx| {
            events[idx] = mapRecordToNetworkEvent(rec, step_id);
        }
        return events;
    }

    /// Converts all captured records on an adapter into `NetworkEvent` rows.
    pub fn allEventsForAdapter(
        allocator: Allocator,
        adapter: NetworkAdapter,
        default_step_id: []const u8,
    ) ![]NetworkEvent {
        const all_records = adapter.capturedRecordsSlice();
        const events = try allocator.alloc(NetworkEvent, all_records.len);
        for (all_records, 0..) |rec, idx| {
            events[idx] = mapRecordToNetworkEvent(rec, default_step_id);
        }
        return events;
    }

    /// Flushes and persists all `.pcapng` forensic captures configured in `ast.networks` to:
    /// 1. `capture.datasource` (`RepositoryRegistry` channel `capture.channel`, default `"pcap_packets"`)
    /// 2. `capture.path` on disk (with ring-buffer rotation `max_file_size_mb` / `max_files`).
    pub fn flushCaptures(self: *EngineNetworkController, repos: *RepositoryRegistry) !void {
        for (self.network_specs) |net_spec| {
            if (!net_spec.capture.enabled) continue;
            const adapter = self.active_registry.get(net_spec.id) orelse continue;
            const pcap_bytes = adapter.pcapBytes() orelse continue;
            if (pcap_bytes.len == 0) continue;

            // 1. Persist to configured Datasource Repository (`capture.datasource`)
            if (net_spec.capture.datasource) |ds_name| {
                if (repos.get(ds_name)) |repo| {
                    const ch_name = if (net_spec.capture.channel.len > 0)
                        net_spec.capture.channel
                    else
                        "pcap_packets";
                    const handle = PayloadHandle.fromSlice(u8, pcap_bytes);
                    try repo.writePayload(ch_name, handle);
                }
            }

            // 2. Persist to configured File Path (`capture.path`) with ring-buffer rotation
            if (net_spec.capture.path) |file_path| {
                if (file_path.len > 0) {
                    try writePcapWithRotation(
                        self.allocator,
                        file_path,
                        pcap_bytes,
                        net_spec.capture.max_file_size_mb,
                        net_spec.capture.max_files,
                    );
                }
            }
        }
    }
};

pub fn mapRecordToNetworkEvent(rec: CapturedExchangeRecord, fallback_step_id: []const u8) NetworkEvent {
    const step_id = extractStepIdFromTraceTag(rec.trace_tag) orelse fallback_step_id;
    return .{
        .event_id = @intCast(rec.sequence_id),
        .step_id = step_id,
        .timestamp = @intCast(rec.timestamp_ms),
        .protocol = rec.scheme,
        .http_method = rec.operation,
        .dst_host = rec.dst_host,
        .dst_port = @intCast(rec.dst_port),
        .uri_path = rec.resource,
        .proxy_used = rec.proxy_used,
        .status_code = @intCast(rec.status_code),
        .latency_ms = @intCast(rec.latency_ms),
        .verdict = rec.verdict.asText(),
    };
}

fn extractStepIdFromTraceTag(trace_tag: []const u8) ?[]const u8 {
    const prefix = "step_id=";
    const start_idx = std.mem.indexOf(u8, trace_tag, prefix) orelse return null;
    const after = trace_tag[start_idx + prefix.len ..];
    const end_idx = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    const val = after[0..end_idx];
    return if (val.len > 0) val else null;
}

pub fn mapNetErrorToHostError(err: network_mod.NetError) abi.HostError_ABI {
    return switch (err) {
        error.InvalidUri => .invalid_argument,
        error.NetworkPolicyDenied, error.UnsupportedProtocolScheme => .network_policy_denied,
        error.NetworkRateLimited => .network_rate_limited,
        error.NetworkAcquireTimeout => .network_acquire_timeout,
        error.NetworkUpstreamError => .network_upstream_error,
        error.StreamNotFound => .not_found,
        error.OutOfMemory => .out_of_memory,
    };
}

fn writePcapWithRotation(
    allocator: Allocator,
    base_path: []const u8,
    pcap_bytes: []const u8,
    max_file_size_mb: usize,
    max_files: usize,
) !void {
    const max_bytes: usize = if (max_file_size_mb > 0)
        max_file_size_mb * 1024 * 1024
    else
        pcap_bytes.len;

    if (max_bytes == 0 or pcap_bytes.len <= max_bytes or max_files <= 1) {
        try runner_mod.writeFileBytes(allocator, base_path, pcap_bytes);
        return;
    }

    // Ring-buffer rotation across `<base_path>.0`, `<base_path>.1`, ... up to `max_files`
    var offset: usize = 0;
    var part_idx: usize = 0;
    while (offset < pcap_bytes.len) : (part_idx += 1) {
        const chunk_len = @min(max_bytes, pcap_bytes.len - offset);
        const slot = part_idx % max_files;
        const rotated_path = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base_path, slot });
        defer allocator.free(rotated_path);

        try runner_mod.writeFileBytes(allocator, rotated_path, pcap_bytes[offset .. offset + chunk_len]);
        offset += chunk_len;
    }

    // Also write the primary file so tools inspecting `base_path` directly find valid PCAPNG data
    try runner_mod.writeFileBytes(allocator, base_path, pcap_bytes);
}
