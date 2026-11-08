const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_plugin");
const dataflow = @import("flowdata_dataflow");
const ast_mod = @import("../../ast/ast.zig");
const network_mod = @import("../../network/mod.zig");

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

pub const TaskExecutionRequest = struct {
    allocator: Allocator,
    input_payload: PayloadHandle,
    input_bytes: []const u8,
    params: []const ast_mod.KeyValueParam,
    workers: u32 = 1,
    net_bridge: ?NetworkBridge = null,
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
    return .{
        .ptr = abi_payload.ptr orelse &{},
        .len = abi_payload.len,
        .element_size = abi_payload.element_size,
        .element_align = @truncate(abi_payload.element_align),
        .is_stream = abi_payload.is_stream,
        .type_name = fallback_type_name,
        .reflect_ctx = if (abi_payload.reflect_fn) |rf| @ptrCast(rf) else null,
        .reflect_ctx_fn = if (abi_payload.reflect_fn != null) &reflectAbiBridge else null,
    };
}

/// Converts a native `dataflow.PayloadHandle` into a C-ABI `PayloadHandle_ABI`.
pub fn toAbiPayload(payload: PayloadHandle) abi.PayloadHandle_ABI {
    return .{
        .ptr = payload.ptr,
        .len = payload.len,
        .element_size = payload.element_size,
        .element_align = payload.element_align,
        .is_stream = payload.is_stream,
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

const ModuleHostState = struct {
    input_slice: []const u8,
    params: []const ast_mod.KeyValueParam,
    net_bridge: ?NetworkBridge = null,

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

    fn getParam(raw_ctx: *abi.TaskContext_ABI, key_ptr: [*:0]const u8, out_val: *abi.Value_ABI) callconv(.c) abi.HostError_ABI {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
        const key = std.mem.span(key_ptr);
        for (self.params) |p| {
            if (std.mem.eql(u8, p.key, key)) {
                if (std.mem.eql(u8, p.value, "true")) {
                    out_val.* = abi.Value_ABI.fromBool(true);
                    return .ok;
                }
                if (std.mem.eql(u8, p.value, "false")) {
                    out_val.* = abi.Value_ABI.fromBool(false);
                    return .ok;
                }
                if (std.fmt.parseInt(i64, p.value, 10)) |iv| {
                    out_val.* = abi.Value_ABI.fromInt(iv);
                    return .ok;
                } else |_| {}
                if (std.fmt.parseFloat(f64, p.value)) |fv| {
                    out_val.* = abi.Value_ABI.fromFloat(fv);
                    return .ok;
                } else |_| {}
                out_val.* = abi.Value_ABI.fromText(p.value);
                return .ok;
            }
        }
        return .not_found;
    }

    fn emitRow(_: *abi.TaskContext_ABI, _: ?[*:0]const u8, _: [*]const abi.NamedField_ABI, _: usize) callconv(.c) abi.HostError_ABI {
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

    fn logEvent(_: *abi.TaskContext_ABI, _: abi.LogLevel_ABI, _: [*]const u8, _: usize) callconv(.c) void {}

    fn netRequest(raw_ctx: *abi.TaskContext_ABI, req_ptr: *const abi.NetRequest_ABI, out_resp: *abi.NetResponse_ABI) callconv(.c) abi.HostError_ABI {
        return netRequestOpaque(raw_ctx.opaque_host_state, req_ptr, out_resp);
    }

    fn netRequestOpaque(opaque_ctx: ?*anyopaque, req_ptr: *const abi.NetRequest_ABI, out_resp: *abi.NetResponse_ABI) callconv(.c) abi.HostError_ABI {
        const ptr = opaque_ctx orelse return .network_policy_denied;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const bridge = self.net_bridge orelse return .network_policy_denied;
        const req = req_ptr.*;
        const res = bridge.vtable.request(
            bridge.ptr,
            req.network_id.asSlice(),
            req.url.asSlice(),
            req.operation.asSlice(),
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
    };
};

/// Executes a resolved module task descriptor across the C-ABI boundary (`execute_blackbox` or `execute`).
pub fn executeTask(
    desc: *const abi.TaskDescriptor_ABI,
    req: TaskExecutionRequest,
) TaskExecutionOutcome {
    var host_state = ModuleHostState{
        .input_slice = req.input_bytes,
        .params = req.params,
        .net_bridge = req.net_bridge,
    };

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
    return .{
        .status = mapAbiStatus(status),
        .output = req.input_payload,
    };
}
