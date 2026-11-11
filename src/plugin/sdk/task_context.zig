const std = @import("std");
const types = @import("../types/mod.zig");
const reader = @import("../reader/mod.zig");
const SdkError = @import("sdk_error.zig").SdkError;
const mapHostError = @import("map_host_error.zig").mapHostError;

const TaskContext_ABI = types.TaskContext_ABI;
const WindowView_ABI = types.WindowView_ABI;
const RowView_ABI = types.RowView_ABI;
const Value_ABI = types.Value_ABI;
const NamedField_ABI = types.NamedField_ABI;
const LogLevel_ABI = types.LogLevel_ABI;
const Slice_ABI = types.Slice_ABI;
const NetRequest_ABI = types.NetRequest_ABI;
const NetResponse_ABI = types.NetResponse_ABI;
const NetStreamHandle_ABI = types.NetStreamHandle_ABI;
const BoundedStreamReader = reader.BoundedStreamReader;
const WindowReader = reader.WindowReader;

/// Ergonomic, safe Zig wrapper around `*TaskContext_ABI` for plugin authors.
/// Eliminates raw pointer/length handling and maps `HostError_ABI` to Zig error unions.
pub const TaskContext = struct {
    raw: *TaskContext_ABI,

    pub fn init(raw: *TaskContext_ABI) TaskContext {
        return .{ .raw = raw };
    }

    // --- 1. Stream Input ---

    pub fn streamSize(self: TaskContext) u64 {
        return self.raw.host.stream_size(self.raw);
    }

    pub fn streamReadAt(self: TaskContext, offset: u64, dest: []u8) SdkError!void {
        if (dest.len == 0) return;
        const rc = self.raw.host.stream_read_at(self.raw, offset, dest.ptr, dest.len);
        try mapHostError(rc);
    }

    /// Returns a capability-mediated `BoundedStreamReader` over `[0, streamSize())`.
    pub fn streamReader(self: TaskContext) BoundedStreamReader {
        return BoundedStreamReader.fromStream(self);
    }

    /// Returns a capability-mediated `WindowReader` over a `WindowView_ABI`.
    pub fn windowReader(self: TaskContext, window: WindowView_ABI) WindowReader {
        return WindowReader.init(self, window);
    }

    // --- 2. Lazy Window Iteration ---

    /// Fetches the next byte window from the default `"windows"` input channel, or `null` on EOF.
    pub fn nextWindow(self: TaskContext) SdkError!?WindowView_ABI {
        var win: WindowView_ABI = undefined;
        const rc = self.raw.host.next_window(self.raw, null, &win);
        if (rc == .end_of_stream) return null;
        try mapHostError(rc);
        return win;
    }

    /// Fetches the next byte window from a named window input channel, or `null` on EOF.
    pub fn nextWindowFrom(self: TaskContext, channel_name: [:0]const u8) SdkError!?WindowView_ABI {
        var win: WindowView_ABI = undefined;
        const rc = self.raw.host.next_window(self.raw, channel_name.ptr, &win);
        if (rc == .end_of_stream) return null;
        try mapHostError(rc);
        return win;
    }

    /// Safely reads `dest.len` bytes from `window` at `relative_offset`.
    pub fn windowReadAt(
        self: TaskContext,
        window: *const WindowView_ABI,
        relative_offset: u64,
        dest: []u8,
    ) SdkError!void {
        if (dest.len == 0) return;
        const rc = self.raw.host.window_read_at(self.raw, window, relative_offset, dest.ptr, dest.len);
        try mapHostError(rc);
    }

    // --- 3. Lazy Relational Row Cursor Iteration ---

    /// Fetches the next row from `cursor_name`, or `null` when all rows have been consumed.
    pub fn nextRow(self: TaskContext, cursor_name: [:0]const u8) SdkError!?RowView_ABI {
        var row: RowView_ABI = undefined;
        const rc = self.raw.host.next_row(self.raw, cursor_name.ptr, &row);
        if (rc == .end_of_stream) return null;
        try mapHostError(rc);
        return row;
    }

    pub fn inputCount(self: TaskContext) usize {
        if (self.raw.host.input_count) |f| {
            return f(self.raw);
        }
        return 1;
    }

    pub fn inputPayload(self: TaskContext, name: [:0]const u8) SdkError!?@import("../types/payload_handle_abi.zig").PayloadHandle_ABI {
        const f = self.raw.host.input_payload orelse return null;
        var out_handle: @import("../types/payload_handle_abi.zig").PayloadHandle_ABI = undefined;
        const rc = f(self.raw, name.ptr, &out_handle);
        if (rc == .not_found) return null;
        try mapHostError(rc);
        return out_handle;
    }

    pub fn executionOptions(self: TaskContext) ?@import("../types/execution_options_abi.zig").ExecutionOptions_ABI {
        const f = self.raw.host.get_execution_options orelse return null;
        var opts: @import("../types/execution_options_abi.zig").ExecutionOptions_ABI = undefined;
        const rc = f(self.raw, &opts);
        if (rc != .ok) return null;
        return opts;
    }

    pub fn workerCount(self: TaskContext) usize {
        if (self.executionOptions()) |opts| {
            return @intCast(opts.workers);
        }
        return 1;
    }

    pub fn parallelFor(
        self: TaskContext,
        total_items: usize,
        workers_budget: usize,
        comptime CtxType: type,
        ctx: *CtxType,
        comptime worker_fn: *const fn (ctx: *CtxType, start: usize, end: usize) u8,
    ) SdkError!void {
        const f = self.raw.host.parallel_for orelse {
            const rc = worker_fn(ctx, 0, total_items);
            if (rc != 0) return SdkError.InvalidOperation;
            return;
        };
        const Trampoline = struct {
            fn run(raw: *anyopaque, start: usize, end: usize) callconv(.c) u8 {
                const typed_ctx: *CtxType = @ptrCast(@alignCast(raw));
                return worker_fn(typed_ctx, start, end);
            }
        };
        const rc = f(self.raw, total_items, workers_budget, &Trampoline.run, ctx);
        try mapHostError(rc);
    }

    pub fn isCancelled(self: TaskContext) bool {
        if (self.raw.host.is_cancelled) |f| {
            return f(self.raw) != 0;
        }
        return false;
    }

    pub fn outputAllocator(self: TaskContext) std.mem.Allocator {
        if (self.raw.host.get_output_allocator) |f| {
            if (f(self.raw)) |mem_ptr| {
                return mem_ptr.toAllocator();
            }
        }
        return std.heap.page_allocator;
    }

    // --- 4. Parameters (`params:`) ---

    pub fn getParam(self: TaskContext, key: [:0]const u8) SdkError!?Value_ABI {
        var val: Value_ABI = undefined;
        const rc = self.raw.host.get_param(self.raw, key.ptr, &val);
        if (rc == .not_found) return null;
        try mapHostError(rc);
        return val;
    }

    pub fn getParamInt(self: TaskContext, key: [:0]const u8, default_val: i64) SdkError!i64 {
        const val = (try self.getParam(key)) orelse return default_val;
        return val.asInt() orelse error.TypeMismatch;
    }

    pub fn getParamFloat(self: TaskContext, key: [:0]const u8, default_val: f64) SdkError!f64 {
        const val = (try self.getParam(key)) orelse return default_val;
        return val.asFloat() orelse error.TypeMismatch;
    }

    pub fn getParamBool(self: TaskContext, key: [:0]const u8, default_val: bool) SdkError!bool {
        const val = (try self.getParam(key)) orelse return default_val;
        return val.asBool() orelse error.TypeMismatch;
    }

    pub fn getParamText(self: TaskContext, key: [:0]const u8, default_val: []const u8) SdkError![]const u8 {
        const val = (try self.getParam(key)) orelse return default_val;
        return val.asText() orelse error.TypeMismatch;
    }

    // --- 5. Relational Output Sink (`emit_row`) ---

    pub fn emitRow(
        self: TaskContext,
        fields: []const NamedField_ABI,
    ) SdkError!void {
        return self.emitRowTo(null, fields);
    }

    pub fn emitRowTo(
        self: TaskContext,
        channel_name: ?[:0]const u8,
        fields: []const NamedField_ABI,
    ) SdkError!void {
        const f_ptr: [*]const NamedField_ABI = if (fields.len > 0) fields.ptr else undefined;
        const ch_ptr = if (channel_name) |c| c.ptr else null;
        const rc = self.raw.host.emit_row(self.raw, ch_ptr, f_ptr, fields.len);
        try mapHostError(rc);
    }

    /// Serializes and emits a strongly-typed struct or primitive scalar row to a named channel.
    pub fn emitTypedRowTo(
        self: TaskContext,
        channel_name: ?[:0]const u8,
        row: anytype,
    ) SdkError!void {
        const T = @TypeOf(row);
        const info = @typeInfo(T);
        switch (info) {
            .@"struct" => |s| {
                var fields: [s.fields.len]NamedField_ABI = undefined;
                inline for (s.fields, 0..) |f, i| {
                    const val = @field(row, f.name);
                    fields[i] = NamedField_ABI.init(f.name, Value_ABI.fromAny(val));
                }
                return self.emitRowTo(channel_name, &fields);
            },
            .int, .float, .bool => {
                const fields = [_]NamedField_ABI{
                    NamedField_ABI.init("value", Value_ABI.fromAny(row)),
                };
                return self.emitRowTo(channel_name, &fields);
            },
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    const fields = [_]NamedField_ABI{
                        NamedField_ABI.init("value", Value_ABI.fromText(row)),
                    };
                    return self.emitRowTo(channel_name, &fields);
                }
                @compileError("Unsupported pointer type in emitTypedRow: " ++ @typeName(T));
            },
            else => @compileError("emitTypedRow expects a struct or primitive scalar type, got " ++ @typeName(T)),
        }
    }

    /// Emits a zero-copy contiguous typed slice directly into an output channel (ARCH-016).
    pub fn emitTypedSlice(
        self: TaskContext,
        channel_name: ?[:0]const u8,
        comptime T: type,
        slice: []const T,
    ) SdkError!void {
        const emit_fn = self.raw.host.emit_typed_slice orelse return error.InvalidOperation;
        const abi_handle = @import("../types/payload_handle_abi.zig").PayloadHandle_ABI.fromSlice(T, slice);
        const ch_ptr = if (channel_name) |c| c.ptr else null;
        const rc = emit_fn(self.raw, ch_ptr, &abi_handle);
        try mapHostError(rc);
    }

    /// Serializes and emits a strongly-typed struct or primitive scalar row at compile-time.
    pub fn emitTypedRow(
        self: TaskContext,
        row: anytype,
    ) SdkError!void {
        return self.emitTypedRowTo(null, row);
    }

    // --- 6. Managed Artifacts & Quarantine ---

    pub fn artifactWriteAt(self: TaskContext, offset: u64, src: []const u8) SdkError!void {
        if (src.len == 0) return;
        const rc = self.raw.host.artifact_write_at(self.raw, offset, src.ptr, src.len);
        try mapHostError(rc);
    }

    pub fn artifactZeroRange(self: TaskContext, offset: u64, length: u64) SdkError!void {
        if (length == 0) return;
        const rc = self.raw.host.artifact_zero_range(self.raw, offset, length);
        try mapHostError(rc);
    }

    pub fn artifactTruncate(self: TaskContext, new_size: u64) SdkError!void {
        const rc = self.raw.host.artifact_truncate(self.raw, new_size);
        try mapHostError(rc);
    }

    pub fn carveToQuarantine(
        self: TaskContext,
        offset: u64,
        length: u64,
        reason_tag: [:0]const u8,
    ) SdkError![64]u8 {
        var sha_hex: [64]u8 = undefined;
        const rc = self.raw.host.carve_to_quarantine(self.raw, offset, length, reason_tag.ptr, &sha_hex);
        try mapHostError(rc);
        return sha_hex;
    }

    // --- 7. Logging ---

    pub fn log(self: TaskContext, level: LogLevel_ABI, msg: []const u8) void {
        const ptr: [*]const u8 = if (msg.len > 0) msg.ptr else "";
        self.raw.host.log_event(self.raw, level, ptr, msg.len);
    }

    pub fn logDebug(self: TaskContext, msg: []const u8) void {
        self.log(.debug, msg);
    }

    pub fn logInfo(self: TaskContext, msg: []const u8) void {
        self.log(.info, msg);
    }

    pub fn logWarn(self: TaskContext, msg: []const u8) void {
        self.log(.warn, msg);
    }

    pub fn logError(self: TaskContext, msg: []const u8) void {
        self.log(.err, msg);
    }

    pub fn logInfoFmt(self: TaskContext, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log_event_truncated";
        self.log(.info, msg);
    }

    pub fn logWarnFmt(self: TaskContext, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log_event_truncated";
        self.log(.warn, msg);
    }

    pub fn logErrorFmt(self: TaskContext, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log_event_truncated";
        self.log(.err, msg);
    }

    // --- 8. Mediated Virtual Network Operations (`networks:`) ---

    /// Executes a protocol-agnostic request through the step's bound Virtual Network Adapter.
    pub fn netRequest(self: TaskContext, req: NetRequest_ABI) SdkError!NetResponse_ABI {
        const net_fn = self.raw.host.net_request orelse return error.NetworkPolicyDenied;
        var resp = NetResponse_ABI{};
        const rc = net_fn(self.raw, &req, &resp);
        try mapHostError(rc);
        return resp;
    }

    /// Convenience helper for GET/read operations on a URI through the step's Virtual Network Adapter.
    pub fn netFetch(self: TaskContext, url: []const u8) SdkError!NetResponse_ABI {
        return self.netRequest(.{
            .url = Slice_ABI.fromSlice(url),
            .operation = Slice_ABI.fromSlice("GET"),
        });
    }

    /// Opens a stateful bidirectional stream (`ws`, `rtmp`, `tcp`, `udp`, `tls`, `quic`) via the step's Virtual Network Adapter.
    pub fn netConnect(self: TaskContext, url: []const u8, operation: []const u8) SdkError!NetStreamHandle_ABI {
        const connect_fn = self.raw.host.net_connect orelse return error.NetworkPolicyDenied;
        const req = NetRequest_ABI{
            .url = Slice_ABI.fromSlice(url),
            .operation = Slice_ABI.fromSlice(operation),
        };
        var handle: NetStreamHandle_ABI = 0;
        const rc = connect_fn(self.raw, &req, &handle);
        try mapHostError(rc);
        return handle;
    }

    pub fn netSend(self: TaskContext, handle: NetStreamHandle_ABI, data: []const u8) SdkError!void {
        if (data.len == 0) return;
        const send_fn = self.raw.host.net_send orelse return error.NetworkPolicyDenied;
        const rc = send_fn(self.raw, handle, data.ptr, data.len);
        try mapHostError(rc);
    }

    pub fn netRecv(self: TaskContext, handle: NetStreamHandle_ABI, dest: []u8) SdkError!usize {
        if (dest.len == 0) return 0;
        const recv_fn = self.raw.host.net_recv orelse return error.NetworkPolicyDenied;
        var read_len: usize = 0;
        const rc = recv_fn(self.raw, handle, dest.ptr, dest.len, &read_len);
        if (rc == .end_of_stream) return 0;
        try mapHostError(rc);
        return read_len;
    }

    pub fn netClose(self: TaskContext, handle: NetStreamHandle_ABI) SdkError!void {
        const close_fn = self.raw.host.net_close orelse return error.NetworkPolicyDenied;
        const rc = close_fn(self.raw, handle);
        try mapHostError(rc);
    }
};
