const std = @import("std");
const types = @import("types.zig");
pub const reader = @import("reader.zig");
pub const ir = @import("ir.zig");

pub const BoundedStreamReader = reader.BoundedStreamReader;
pub const WindowReader = reader.WindowReader;
pub const ClampedSubRegion = reader.ClampedSubRegion;

pub const VIDSEC_ABI_VERSION = types.VIDSEC_ABI_VERSION;
pub const SemVer_ABI = types.SemVer_ABI;
pub const ValueTag_ABI = types.ValueTag_ABI;
pub const Value_ABI = types.Value_ABI;
pub const NamedField_ABI = types.NamedField_ABI;
pub const WindowView_ABI = types.WindowView_ABI;
pub const RowView_ABI = types.RowView_ABI;
pub const LogLevel_ABI = types.LogLevel_ABI;
pub const HostError_ABI = types.HostError_ABI;
pub const TaskStatus_ABI = types.TaskStatus_ABI;
pub const TaskContext_ABI = types.TaskContext_ABI;
pub const TaskDescriptor_ABI = types.TaskDescriptor_ABI;
pub const ModuleManifest_ABI = types.ModuleManifest_ABI;

pub const SdkError = error{
    OutOfBounds,
    InvalidArgument,
    NotFound,
    IoError,
    DbConstraintError,
    PermissionDenied,
    OutOfMemory,
    TypeMismatch,
    UnexpectedHostError,
};

pub fn mapHostError(err: HostError_ABI) SdkError!void {
    return switch (err) {
        .ok => {},
        .end_of_stream => error.UnexpectedHostError,
        .out_of_bounds => error.OutOfBounds,
        .invalid_argument => error.InvalidArgument,
        .not_found => error.NotFound,
        .io_error => error.IoError,
        .db_constraint_error => error.DbConstraintError,
        .permission_denied => error.PermissionDenied,
        .out_of_memory => error.OutOfMemory,
    };
}

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
        channel_name: ?[:0]const u8,
        fields: []const NamedField_ABI,
    ) SdkError!void {
        const ch_ptr: ?[*:0]const u8 = if (channel_name) |c| c.ptr else null;
        const f_ptr: [*]const NamedField_ABI = if (fields.len > 0) fields.ptr else undefined;
        const rc = self.raw.host.emit_row(self.raw, ch_ptr, f_ptr, fields.len);
        try mapHostError(rc);
    }

    /// Serializes and emits a strongly-typed struct row to `channel_name` at compile-time.
    pub fn emitTypedRow(
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
                return self.emitRow(channel_name, &fields);
            },
            else => @compileError("emitTypedRow expects a struct type"),
        }
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
};

/// Declarative specification used with `defineTask` to wrap an idiomatic Zig function
/// `fn (ctx: TaskContext) anyerror!TaskStatus_ABI` into a `callconv(.c)` `TaskDescriptor_ABI`.
pub const ZigTaskSpec = struct {
    name: [:0]const u8,
    description: [:0]const u8 = "",
    output_fields: []const [*:0]const u8 = &.{},
    required_params: []const [*:0]const u8 = &.{},
    run: *const fn (ctx: TaskContext) anyerror!TaskStatus_ABI,
};

/// Wraps a `ZigTaskSpec` at compile time into a C-ABI `TaskDescriptor_ABI`, automatically
/// logging any unhandled Zig error via `ctx.logError(@errorName(err))` and returning `.fatal_error`.
pub fn defineTask(comptime spec: ZigTaskSpec) TaskDescriptor_ABI {
    const Trampoline = struct {
        pub fn execute(raw_ctx: *TaskContext_ABI) callconv(.c) TaskStatus_ABI {
            const ctx = TaskContext.init(raw_ctx);
            if (raw_ctx.abi_version != VIDSEC_ABI_VERSION) {
                ctx.logError("ABI version mismatch in TaskContext_ABI");
                return .fatal_error;
            }
            return spec.run(ctx) catch |err| {
                ctx.logError(@errorName(err));
                return .fatal_error;
            };
        }
    };

    return .{
        .task_name = spec.name.ptr,
        .description = spec.description.ptr,
        .output_fields_ptr = if (spec.output_fields.len > 0) spec.output_fields.ptr else null,
        .output_fields_len = spec.output_fields.len,
        .required_params_ptr = if (spec.required_params.len > 0) spec.required_params.ptr else null,
        .required_params_len = spec.required_params.len,
        .execute = &Trampoline.execute,
    };
}

/// Builds a `ModuleManifest_ABI` at compile time from a module name, semantic version, and slice of tasks.
pub fn defineManifest(
    comptime module_name: [:0]const u8,
    comptime version: SemVer_ABI,
    comptime tasks: []const TaskDescriptor_ABI,
) ModuleManifest_ABI {
    if (tasks.len == 0) {
        @compileError("ModuleManifest_ABI must expose at least one TaskDescriptor_ABI");
    }
    return .{
        .abi_version = VIDSEC_ABI_VERSION,
        .module_name = module_name.ptr,
        .module_version = version,
        .tasks_ptr = tasks.ptr,
        .tasks_len = tasks.len,
    };
}
