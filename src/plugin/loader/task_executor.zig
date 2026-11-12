const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_plugin");
const dataflow = @import("flowdata_dataflow");
const ast_mod = @import("../../ast/ast.zig");
const network_mod = @import("../../transport/outbound/mod.zig");
const Mutex = @import("../../concurrency/mod.zig").Mutex;

pub const PayloadHandle = dataflow.PayloadHandle;
pub const ReflectedValue = dataflow.ReflectedValue;
pub const NetResult = network_mod.NetResult;
pub const NetError = network_mod.NetError;

pub const TaskOutcomeStatus = enum {
    ok,
    recoverable_warning,
    halt_pipeline,
    fatal_error,
};

pub const TaskExecutionOutcome = struct {
    status: TaskOutcomeStatus,
    output: PayloadHandle,
    channel_outputs: std.StringHashMapUnmanaged(PayloadHandle) = .empty,
};

/// Domain-agnostic host network bridge passed from the Engine into the Module Task Executor.
pub const NetworkBridge = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (
            ptr: *anyopaque,
            network_id: []const u8,
            url: []const u8,
            operation: []const u8,
            headers: []const network_mod.HttpHeader,
            body: []const u8,
        ) NetError!NetResult,
        connect: *const fn (
            ptr: *anyopaque,
            network_id: []const u8,
            url: []const u8,
            operation: []const u8,
        ) NetError!u64,
        send: *const fn (
            ptr: *anyopaque,
            handle: u64,
            payload: []const u8,
        ) NetError!void,
        recv: *const fn (
            ptr: *anyopaque,
            handle: u64,
            dest: []u8,
        ) NetError!usize,
        close: *const fn (
            ptr: *anyopaque,
            handle: u64,
        ) NetError!void,
    };
};

pub const BoundInput = struct {
    name: []const u8,
    payload: PayloadHandle,
};

pub const TaskExecutionRequest = struct {
    allocator: Allocator,
    input_payload: PayloadHandle,
    input_bytes: []const u8,
    params: []const ast_mod.KeyValueParam,
    workers: u32 = 1,
    net_bridge: ?NetworkBridge = null,
    bound_inputs: []const BoundInput = &.{},
    is_cancelled_flag: *const bool = &false_flag,
    worker_pool: ?*@import("../../concurrency/mod.zig").WorkerPool = null,

    const false_flag: bool = false;
};

/// Bridges an `abi.ReflectFn_ABI` function pointer into `dataflow.PayloadHandle`'s pure
/// `ContextualReflectFn` without exposing ABI types to `flowdata_dataflow`.
pub fn reflectAbiBridge(
    ctx: *const anyopaque,
    ptr: *const anyopaque,
    field_name: []const u8,
) ?ReflectedValue {
    const rf_abi: abi.ReflectFn_ABI = @ptrCast(@alignCast(ctx));
    const res = rf_abi(ptr, field_name.ptr, field_name.len);
    return switch (res.tag) {
        .none => null,
        .int => .{ .int = res.int_val },
        .uint => .{ .uint = @intCast(res.int_val) },
        .float => .{ .float = res.float_val },
        .boolean => .{ .boolean = res.int_val != 0 },
        .string => if (res.str_ptr) |sptr| .{ .string = sptr[0..res.str_len] } else null,
    };
}

/// Converts a C-ABI `PayloadHandle_ABI` into a native `dataflow.PayloadHandle`.
pub fn fromAbiPayload(abi_payload: abi.PayloadHandle_ABI, fallback_type_name: []const u8) PayloadHandle {
    const tname = if (abi_payload.typeName().len > 0)
        abi_payload.typeName()
    else
        fallback_type_name;

    const repr: dataflow.PayloadRepr = switch (abi_payload.repr) {
        .bytes => .bytes,
        .typed => .typed,
        .dynamic => .dynamic,
    };

    return .{
        .ptr = abi_payload.ptr orelse &{},
        .len = abi_payload.len,
        .element_size = abi_payload.element_size,
        .element_align = @truncate(abi_payload.element_align),
        .is_stream = abi_payload.is_stream,
        .type_name = tname,
        .reflect_ctx = if (abi_payload.reflect_fn) |rf| @ptrCast(rf) else null,
        .reflect_ctx_fn = if (abi_payload.reflect_fn != null) &reflectAbiBridge else null,
        .abi_reflect_fn = if (abi_payload.reflect_fn) |rf| @ptrCast(rf) else null,
        .repr = repr,
        .schema_id = abi_payload.schema_id,
    };
}

/// Converts a native `dataflow.PayloadHandle` into a C-ABI `PayloadHandle_ABI`.
pub fn toAbiPayload(payload: PayloadHandle) abi.PayloadHandle_ABI {
    const abi_repr: abi.PayloadRepr_ABI = switch (payload.repr) {
        .bytes => .bytes,
        .typed => .typed,
        .dynamic => .dynamic,
    };

    return .{
        .ptr = payload.ptr,
        .len = payload.len,
        .element_size = payload.element_size,
        .element_align = payload.element_align,
        .is_stream = payload.is_stream,
        .reflect_fn = if (payload.abi_reflect_fn) |rf| @ptrCast(rf) else null,
        .repr = abi_repr,
        .schema_id = payload.schema_id,
        .type_name_ptr = payload.type_name.ptr,
        .type_name_len = payload.type_name.len,
    };
}

pub fn mapNetErrorToHostError(err: NetError) abi.HostError_ABI {
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

fn mapAbiStatus(status: abi.TaskStatus_ABI) TaskOutcomeStatus {
    return switch (status) {
        .ok => .ok,
        .recoverable_warning => .recoverable_warning,
        .halt_pipeline => .halt_pipeline,
        .fatal_error => .fatal_error,
    };
}

fn valueAbiToReflected(alloc: Allocator, v: abi.Value_ABI) dataflow.ReflectedValue {
    return switch (v.tag) {
        .null_val => .none,
        .boolean => .{ .boolean = v.asBool() orelse false },
        .int64 => .{ .int = v.asInt() orelse 0 },
        .float64 => .{ .float = v.asFloat() orelse 0.0 },
        .text => if (v.asText()) |t| .{ .string = alloc.dupe(u8, t) catch t } else .none,
        .blob => if (v.asBlob()) |b| .{ .bytes = alloc.dupe(u8, b) catch b } else .none,
    };
}

const ModuleHostState = struct {
    allocator: Allocator,
    input_slice: []const u8,
    input_payload: PayloadHandle,
    params: []const ast_mod.KeyValueParam,
    net_bridge: ?NetworkBridge = null,
    bound_inputs: []const BoundInput = &.{},
    workers: u32 = 1,
    is_cancelled_flag: *const bool,
    worker_pool: ?*@import("../../concurrency/mod.zig").WorkerPool = null,
    emitted_records: std.ArrayListUnmanaged(dataflow.DynamicRecord) = .empty,
    channel_outputs: std.StringHashMapUnmanaged(PayloadHandle) = .empty,
    primary_emitted_slice: ?PayloadHandle = null,
    mem_abi: abi.MemContext_ABI = undefined,

    fn streamSize(raw_ctx: *abi.TaskContext_ABI) callconv(.c) u64 {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        return self.input_slice.len;
    }

    fn streamReadAt(raw_ctx: *abi.TaskContext_ABI, offset: u64, dest_ptr: [*]u8, len: usize) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        const end = std.math.add(u64, offset, len) catch return .out_of_bounds;
        if (end > self.input_slice.len) return .out_of_bounds;
        const start: usize = @intCast(offset);
        @memcpy(dest_ptr[0..len], self.input_slice[start .. start + len]);
        return .ok;
    }

    fn nextWindow(_: *abi.TaskContext_ABI, _: ?[*:0]const u8, _: *abi.WindowView_ABI) callconv(.c) abi.HostError_ABI {
        return .end_of_stream;
    }

    fn windowReadAt(_: *abi.TaskContext_ABI, _: *const abi.WindowView_ABI, _: u64, _: [*]u8, _: usize) callconv(.c) abi.HostError_ABI {
        return .out_of_bounds;
    }

    fn nextRow(_: *abi.TaskContext_ABI, _: [*:0]const u8, _: *abi.RowView_ABI) callconv(.c) abi.HostError_ABI {
        return .end_of_stream;
    }

    fn reflectedToAbiValue(rval: dataflow.ReflectedValue, out_val: *abi.Value_ABI) bool {
        switch (rval) {
            .boolean => |b| {
                out_val.* = abi.Value_ABI.fromBool(b);
                return true;
            },
            .int => |iv| {
                out_val.* = abi.Value_ABI.fromInt(iv);
                return true;
            },
            .uint => |uv| {
                out_val.* = abi.Value_ABI.fromInt(@intCast(uv));
                return true;
            },
            .float => |fv| {
                out_val.* = abi.Value_ABI.fromFloat(fv);
                return true;
            },
            .string => |s| {
                out_val.* = abi.Value_ABI.fromText(s);
                return true;
            },
            .bytes => |b| {
                out_val.* = abi.Value_ABI.fromBlob(b);
                return true;
            },
            else => return false,
        }
    }

    fn extractReflectedValue(payload: PayloadHandle, key: []const u8) ?dataflow.ReflectedValue {
        if (payload.getReflected(key)) |rval| return rval;
        if (payload.repr == .dynamic and payload.len > 0) {
            const records: [*]const dataflow.DynamicRecord = @ptrCast(@alignCast(payload.ptr));
            const rec = &records[0];
            if (rec.getReflected(key)) |rval| return rval;
            if (rec.getReflected("xml_data")) |rval| return rval;
            if (rec.getReflected("value")) |rval| return rval;
            if (rec.fields.len == 1) return rec.fields[0].value;
        }
        if (payload.getReflected("xml_data")) |rval| return rval;
        if (payload.getReflected("value")) |rval| return rval;
        return null;
    }

    fn getParam(raw_ctx: *abi.TaskContext_ABI, key_ptr: [*:0]const u8, out_val: *abi.Value_ABI) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        const key = std.mem.span(key_ptr);
        for (self.params) |p| {
            if (std.mem.eql(u8, p.key, key)) {
                out_val.* = abi.Value_ABI.fromText(p.value);
                return .ok;
            }
        }

        // Check if field is present in bound_inputs (bound via inputs: in pipeline YAML)
        for (self.bound_inputs) |bi| {
            if (std.mem.eql(u8, bi.name, key)) {
                if (extractReflectedValue(bi.payload, key)) |rval| {
                    if (reflectedToAbiValue(rval, out_val)) return .ok;
                }
                if (bi.payload.repr == .bytes or std.mem.eql(u8, bi.payload.type_name, "u8")) {
                    const bytes: [*]const u8 = @ptrCast(bi.payload.ptr);
                    out_val.* = abi.Value_ABI.fromText(bytes[0..bi.payload.len]);
                    return .ok;
                }
            }
        }

        // Check if field is present in input_payload (propagated from previous tasks or datasources)
        if (self.input_payload.getReflected(key)) |rval| {
            if (reflectedToAbiValue(rval, out_val)) return .ok;
        }

        // Check if any bound input contains the field
        for (self.bound_inputs) |bi| {
            if (bi.payload.getReflected(key)) |rval| {
                if (reflectedToAbiValue(rval, out_val)) return .ok;
            }
        }

        return .not_found;
    }

    fn emitRow(raw_ctx: *abi.TaskContext_ABI, _: ?[*:0]const u8, fields_ptr: [*]const abi.NamedField_ABI, fields_len: usize) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        const dyn_fields = self.allocator.alloc(dataflow.DynamicField, fields_len) catch return .out_of_memory;
        for (0..fields_len) |i| {
            const nf = fields_ptr[i];
            const name_owned = self.allocator.dupe(u8, nf.nameSlice()) catch return .out_of_memory;
            dyn_fields[i] = .{
                .name = name_owned,
                .value = valueAbiToReflected(self.allocator, nf.value),
            };
        }
        self.emitted_records.append(self.allocator, dataflow.DynamicRecord.init(dyn_fields)) catch return .out_of_memory;
        return .ok;
    }

    fn artifactWriteAt(_: *abi.TaskContext_ABI, _: u64, _: [*]const u8, _: usize) callconv(.c) abi.HostError_ABI {
        return .ok;
    }

    fn artifactZeroRange(_: *abi.TaskContext_ABI, _: u64, _: u64) callconv(.c) abi.HostError_ABI {
        return .ok;
    }

    fn artifactTruncate(_: *abi.TaskContext_ABI, _: u64) callconv(.c) abi.HostError_ABI {
        return .ok;
    }

    fn carveToQuarantine(_: *abi.TaskContext_ABI, _: u64, _: u64, _: [*:0]const u8, _: *[64]u8) callconv(.c) abi.HostError_ABI {
        return .ok;
    }

    var log_mutex: Mutex = .{};

    fn logEvent(_: *abi.TaskContext_ABI, level: abi.LogLevel_ABI, msg_ptr: [*]const u8, len: usize) callconv(.c) void {
        const msg = if (len > 0) msg_ptr[0..len] else "";
        const lvl_str = switch (level) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
        log_mutex.lock();
        defer log_mutex.unlock();
        std.debug.print("[Task {s}] {s}\n", .{ lvl_str, msg });
    }

    fn netRequest(raw_ctx: *abi.TaskContext_ABI, req_ptr: *const abi.NetRequest_ABI, out_resp: *abi.NetResponse_ABI) callconv(.c) abi.HostError_ABI {
        return netRequestOpaque(raw_ctx.opaque_host_state, req_ptr, out_resp);
    }

    fn netRequestOpaque(opaque_ctx: ?*anyopaque, req_ptr: *const abi.NetRequest_ABI, out_resp: *abi.NetResponse_ABI) callconv(.c) abi.HostError_ABI {
        const ptr = opaque_ctx orelse return .network_policy_denied;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const bridge = self.net_bridge orelse return .network_policy_denied;
        const req = req_ptr.*;

        var headers_buf: [32]network_mod.HttpHeader = undefined;
        var headers_len: usize = 0;
        if (req.headers_ptr) |h_ptr| {
            headers_len = @min(req.headers_len, headers_buf.len);
            for (0..headers_len) |i| {
                const item = h_ptr[i];
                headers_buf[i] = .{
                    .name = item.nameSlice(),
                    .value = item.value.asText() orelse "",
                };
            }
        }

        const res = bridge.vtable.request(
            bridge.ptr,
            req.network_id.asSlice(),
            req.url.asSlice(),
            req.operation.asSlice(),
            headers_buf[0..headers_len],
            req.body.asSlice(),
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

    fn netConnect(raw_ctx: *abi.TaskContext_ABI, req_ptr: *const abi.NetRequest_ABI, out_handle: *abi.NetStreamHandle_ABI) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        const bridge = self.net_bridge orelse return .network_policy_denied;
        const req = req_ptr.*;
        const handle = bridge.vtable.connect(
            bridge.ptr,
            req.network_id.asSlice(),
            req.url.asSlice(),
            req.operation.asSlice(),
        ) catch |err| return mapNetErrorToHostError(err);
        out_handle.* = handle;
        return .ok;
    }

    fn netSend(raw_ctx: *abi.TaskContext_ABI, handle: abi.NetStreamHandle_ABI, src_ptr: [*]const u8, len: usize) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        const bridge = self.net_bridge orelse return .network_policy_denied;
        const payload = if (len > 0) src_ptr[0..len] else &.{};
        bridge.vtable.send(bridge.ptr, handle, payload) catch |err| return mapNetErrorToHostError(err);
        return .ok;
    }

    fn netRecv(raw_ctx: *abi.TaskContext_ABI, handle: abi.NetStreamHandle_ABI, dest_ptr: [*]u8, max_len: usize, out_read_len: *usize) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        const bridge = self.net_bridge orelse return .network_policy_denied;
        if (max_len == 0) {
            out_read_len.* = 0;
            return .ok;
        }
        const n = bridge.vtable.recv(bridge.ptr, handle, dest_ptr[0..max_len]) catch |err| return mapNetErrorToHostError(err);
        out_read_len.* = n;
        if (n == 0) return .end_of_stream;
        return .ok;
    }

    fn netClose(raw_ctx: *abi.TaskContext_ABI, handle: abi.NetStreamHandle_ABI) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        const bridge = self.net_bridge orelse return .network_policy_denied;
        bridge.vtable.close(bridge.ptr, handle) catch |err| return mapNetErrorToHostError(err);
        return .ok;
    }

    fn inputCount(raw_ctx: *abi.TaskContext_ABI) callconv(.c) usize {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        return self.bound_inputs.len;
    }

    fn inputPayload(raw_ctx: *abi.TaskContext_ABI, name_ptr: [*:0]const u8, out: *abi.PayloadHandle_ABI) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        const name = std.mem.span(name_ptr);
        for (self.bound_inputs) |bi| {
            if (std.mem.eql(u8, bi.name, name)) {
                out.* = toAbiPayload(bi.payload);
                return .ok;
            }
        }
        if (std.mem.eql(u8, name, "stream") or std.mem.eql(u8, name, "input") or std.mem.eql(u8, name, "primary") or name.len == 0) {
            if (self.bound_inputs.len > 0) {
                for (self.bound_inputs) |bi| {
                    if (bi.payload.is_stream) {
                        out.* = toAbiPayload(bi.payload);
                        return .ok;
                    }
                }
                out.* = toAbiPayload(self.bound_inputs[0].payload);
                return .ok;
            }
            out.* = toAbiPayload(self.input_payload);
            return .ok;
        }
        return .not_found;
    }

    fn getOutputAllocator(raw_ctx: *abi.TaskContext_ABI) callconv(.c) ?*const abi.MemContext_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        return &self.mem_abi;
    }

    fn getExecutionOptions(raw_ctx: *abi.TaskContext_ABI, out_options: *abi.ExecutionOptions_ABI) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        out_options.* = .{
            .workers = self.workers,
            .opaque_net_ctx = self,
            .net_request_fn = &netRequestOpaque,
            .opaque_worker_pool = self.worker_pool,
        };
        return .ok;
    }

    fn hostParallelFor(
        raw_ctx: *abi.TaskContext_ABI,
        total_items: usize,
        workers_budget: usize,
        worker_fn: *const fn (worker_ctx: *anyopaque, start: usize, end: usize) callconv(.c) u8,
        worker_ctx: *anyopaque,
    ) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        if (self.worker_pool) |pool| {
            const Wrapper = struct {
                w_fn: *const fn (*anyopaque, usize, usize) callconv(.c) u8,
                w_ctx: *anyopaque,
                fn run(w: @This(), start: usize, end: usize) anyerror!void {
                    const rc = w.w_fn(w.w_ctx, start, end);
                    if (rc != 0) return error.WorkerFailed;
                }
            };
            pool.parallelFor(total_items, workers_budget, Wrapper, .{ .w_fn = worker_fn, .w_ctx = worker_ctx }, Wrapper.run) catch return .io_error;
            return .ok;
        } else {
            const rc = worker_fn(worker_ctx, 0, total_items);
            return if (rc == 0) .ok else .io_error;
        }
    }

    fn isCancelled(raw_ctx: *abi.TaskContext_ABI) callconv(.c) u8 {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        return if (self.is_cancelled_flag.*) 1 else 0;
    }

    fn emitTypedSlice(raw_ctx: *abi.TaskContext_ABI, ch_name: ?[*:0]const u8, slice_payload: *const abi.PayloadHandle_ABI) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        const channel = if (ch_name) |c| std.mem.span(c) else "out";
        const native_handle = fromAbiPayload(slice_payload.*, slice_payload.typeName());
        self.channel_outputs.put(self.allocator, channel, native_handle) catch return .out_of_memory;
        if (self.primary_emitted_slice == null or std.mem.eql(u8, channel, "out")) {
            self.primary_emitted_slice = native_handle;
        }
        return .ok;
    }

    const vtable = abi.HostApiVTable_ABI{
        .stream_size = &streamSize,
        .stream_read_at = &streamReadAt,
        .next_window = &nextWindow,
        .window_read_at = &windowReadAt,
        .next_row = &nextRow,
        .get_param = &getParam,
        .emit_row = &emitRow,
        .artifact_write_at = &artifactWriteAt,
        .artifact_zero_range = &artifactZeroRange,
        .artifact_truncate = &artifactTruncate,
        .carve_to_quarantine = &carveToQuarantine,
        .log_event = &logEvent,
        .net_request = &netRequest,
        .net_connect = &netConnect,
        .net_send = &netSend,
        .net_recv = &netRecv,
        .net_close = &netClose,
        .input_count = &inputCount,
        .input_payload = &inputPayload,
        .get_output_allocator = &getOutputAllocator,
        .get_execution_options = &getExecutionOptions,
        .is_cancelled = &isCancelled,
        .emit_typed_slice = &emitTypedSlice,
        .parallel_for = &hostParallelFor,
    };
};

/// Executes a resolved module task descriptor across the C-ABI boundary (`execute_blackbox` or `execute`).
pub fn executeTask(
    desc: *const abi.TaskDescriptor_ABI,
    req: TaskExecutionRequest,
) TaskExecutionOutcome {
    var host_state = ModuleHostState{
        .allocator = req.allocator,
        .input_slice = req.input_bytes,
        .input_payload = req.input_payload,
        .params = req.params,
        .net_bridge = req.net_bridge,
        .bound_inputs = req.bound_inputs,
        .workers = req.workers,
        .is_cancelled_flag = req.is_cancelled_flag,
        .worker_pool = req.worker_pool,
    };
    host_state.mem_abi = abi.MemContext_ABI.fromAllocator(&host_state.allocator);

    if (desc.execute_blackbox) |bb_fn| {
        var alloc_copy = req.allocator;
        var mem = abi.MemContext_ABI.fromAllocator(&alloc_copy);
        const in_abi = toAbiPayload(req.input_payload);
        const options = abi.ExecutionOptions_ABI{
            .workers = req.workers,
            .opaque_net_ctx = &host_state,
            .net_request_fn = &ModuleHostState.netRequestOpaque,
        };

        const res = bb_fn(&mem, in_abi, options);
        return .{
            .status = mapAbiStatus(res.status),
            .output = fromAbiPayload(res.payload, req.input_payload.type_name),
        };
    }

    var raw_ctx = abi.TaskContext_ABI{
        .opaque_host_state = &host_state,
        .host = &ModuleHostState.vtable,
    };
    const status = desc.execute(&raw_ctx);

    const out_payload = if (host_state.primary_emitted_slice) |ps|
        ps
    else if (host_state.emitted_records.items.len > 0)
        PayloadHandle.fromSlice(dataflow.DynamicRecord, host_state.emitted_records.items)
    else if (desc.isPassthrough())
        req.input_payload
    else
        PayloadHandle.empty();

    return .{
        .status = mapAbiStatus(status),
        .output = out_payload,
        .channel_outputs = host_state.channel_outputs,
    };
}
