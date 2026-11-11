const std = @import("std");
const Allocator = std.mem.Allocator;
const ast_mod = @import("../ast/ast.zig");
const dataflow = @import("flowdata_dataflow");
const repository_mod = @import("../repository/mod.zig");
const network_mod = @import("../transport/outbound/mod.zig");
const runner_mod = @import("runner.zig");
const Mutex = @import("../concurrency/mod.zig").Mutex;

pub const NetworkRegistry = network_mod.NetworkRegistry;
pub const NetworkAdapter = network_mod.NetworkAdapter;
pub const CapturedExchangeRecord = network_mod.CapturedExchangeRecord;
pub const NetStreamId = network_mod.NetStreamId;
pub const NetResult = network_mod.NetResult;
pub const NetError = network_mod.NetError;
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
/// and `network.captured_events` dataflow materialization.
pub const EngineNetworkController = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    owned_registry: ?NetworkRegistry = null,
    external_registry: ?*NetworkRegistry = null,
    default_network_id: []const u8 = "isolated",
    network_specs: []const ast_mod.NetworkSpec = &.{},
    stream_table: std.AutoHashMapUnmanaged(u64, ActiveStreamEntry) = .empty,
    next_stream_handle: u64 = 1,
    stream_mutex: Mutex = .{},

    pub fn init(
        allocator: Allocator,
        ast: ast_mod.PipelineAST,
        external_registry: ?*NetworkRegistry,
    ) !EngineNetworkController {
        var self = EngineNetworkController{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .external_registry = external_registry,
            .default_network_id = ast.runtime.default_network,
            .network_specs = ast.networks,
        };
        errdefer self.deinit();

        if (external_registry == null) {
            self.owned_registry = NetworkRegistry.init(allocator);
        }

        const reg = self.registry();
        for (ast.networks) |net_spec| {
            _ = try reg.resolveOrCreate(net_spec);
        }
        _ = try reg.ensureBuiltinIsolated(ast.runtime.default_network);

        return self;
    }

    pub fn registry(self: *EngineNetworkController) *NetworkRegistry {
        if (self.external_registry) |ext| return ext;
        return &self.owned_registry.?;
    }

    pub fn registryConst(self: *const EngineNetworkController) *const NetworkRegistry {
        if (self.external_registry) |ext| return ext;
        return &self.owned_registry.?;
    }

    pub fn deinit(self: *EngineNetworkController) void {
        self.stream_mutex.lock();
        var it = self.stream_table.valueIterator();
        while (it.next()) |entry| {
            entry.adapter.streamClose(entry.stream_id);
        }
        self.stream_table.deinit(self.allocator);
        self.stream_mutex.unlock();
        if (self.owned_registry) |*reg| {
            reg.deinit();
        }
        self.arena.deinit();
    }

    /// Resolves the primary `NetworkAdapter` bound to a pipeline task step.
    pub fn resolveStepAdapter(self: *EngineNetworkController, task_spec: ast_mod.TaskStepSpec) !NetworkAdapter {
        const net_id = task_spec.primaryNetwork(self.default_network_id);
        const reg = self.registry();
        return reg.get(net_id) orelse try reg.ensureBuiltinIsolated(net_id);
    }

    /// Resolves either the explicit `network_id` requested or falls back to `primary_adapter`.
    pub fn resolveRequestAdapter(
        self: *const EngineNetworkController,
        primary_adapter: ?NetworkAdapter,
        explicit_network_id: []const u8,
    ) ResultAdapter {
        if (explicit_network_id.len > 0) {
            if (self.registryConst().get(explicit_network_id)) |ad| {
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

    /// Executes a transactional network request on the resolved step adapter.
    pub fn executeRequest(
        self: *EngineNetworkController,
        step_id: []const u8,
        task_name: []const u8,
        primary_adapter: ?NetworkAdapter,
        network_id: []const u8,
        url: []const u8,
        operation: []const u8,
        headers: []const network_mod.HttpHeader,
        body: []const u8,
    ) NetError!NetResult {
        const target = switch (self.resolveRequestAdapter(primary_adapter, network_id)) {
            .adapter => |a| a,
            .not_found => return error.StreamNotFound,
            .denied => return error.NetworkPolicyDenied,
        };

        const trace_tag = self.formatTraceTag(step_id, task_name);
        return target.execute(url, operation, headers, body, trace_tag);
    }

    /// Opens a stateful stream (`ws`, `rtmp`, `grpc`, `tcp`, `udp`, `tls`).
    pub fn connectStream(
        self: *EngineNetworkController,
        step_id: []const u8,
        task_name: []const u8,
        primary_adapter: ?NetworkAdapter,
        network_id: []const u8,
        url: []const u8,
        operation: []const u8,
    ) NetError!u64 {
        const target = switch (self.resolveRequestAdapter(primary_adapter, network_id)) {
            .adapter => |a| a,
            .not_found => return error.StreamNotFound,
            .denied => return error.NetworkPolicyDenied,
        };

        const trace_tag = self.formatTraceTag(step_id, task_name);
        const adapter_stream_id = try target.connectStream(url, operation, trace_tag);

        self.stream_mutex.lock();
        defer self.stream_mutex.unlock();
        const stream_handle = self.next_stream_handle;
        self.next_stream_handle += 1;

        try self.stream_table.put(self.allocator, stream_handle, .{
            .adapter = target,
            .stream_id = adapter_stream_id,
        });

        return stream_handle;
    }

    /// Sends bytes over an active stream.
    pub fn sendStream(
        self: *EngineNetworkController,
        handle: u64,
        payload: []const u8,
    ) NetError!void {
        self.stream_mutex.lock();
        const entry = self.stream_table.get(handle) orelse {
            self.stream_mutex.unlock();
            return error.StreamNotFound;
        };
        self.stream_mutex.unlock();
        _ = try entry.adapter.streamSend(entry.stream_id, payload);
    }

    /// Receives bytes from an active stream.
    pub fn recvStream(
        self: *EngineNetworkController,
        handle: u64,
        dest: []u8,
    ) NetError!usize {
        self.stream_mutex.lock();
        const entry = self.stream_table.get(handle) orelse {
            self.stream_mutex.unlock();
            return error.StreamNotFound;
        };
        self.stream_mutex.unlock();
        if (dest.len == 0) return 0;
        return entry.adapter.streamRecv(entry.stream_id, dest);
    }

    /// Closes an active stream.
    pub fn closeStream(
        self: *EngineNetworkController,
        handle: u64,
    ) NetError!void {
        self.stream_mutex.lock();
        const kv = self.stream_table.fetchRemove(handle) orelse {
            self.stream_mutex.unlock();
            return error.StreamNotFound;
        };
        self.stream_mutex.unlock();
        kv.value.adapter.streamClose(kv.value.stream_id);
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
