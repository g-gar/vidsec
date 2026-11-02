const std = @import("std");

/// Current C-ABI protocol version between the `vidsec v2` Host Engine and `.so` Task Plugins.
pub const VIDSEC_ABI_VERSION: u32 = 2;

/// Exported symbol name that every `vidsec v2` dynamic module (`.so`) must expose.
pub const MANIFEST_SYMBOL_NAME: [:0]const u8 = "vidsec_module_manifest";

/// Semantic version of a plugin module.
pub const SemVer_ABI = extern struct {
    major: u16,
    minor: u16,
    patch: u16,

    pub fn format(self: SemVer_ABI, writer: anytype) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

/// Discriminant for `Value_ABI` with a strict 1:1 mapping to `schemas.yaml` and SQLite `STRICT` types.
pub const ValueTag_ABI = enum(u32) {
    null_val = 0,
    int64 = 1,
    float64 = 2,
    boolean = 3,
    text = 4,
    blob = 5,
};

/// Non-owning byte slice representation across the C-ABI boundary.
pub const Slice_ABI = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn fromSlice(s: []const u8) Slice_ABI {
        return .{
            .ptr = if (s.len > 0) s.ptr else "",
            .len = s.len,
        };
    }

    pub fn toSlice(self: Slice_ABI) []const u8 {
        if (self.len == 0) return &.{};
        return self.ptr[0..self.len];
    }
};

/// Untagged C union holding the payload of a `Value_ABI`.
pub const ValuePayload_ABI = extern union {
    int64: i64,
    float64: f64,
    boolean: bool,
    slice: Slice_ABI,
};

/// Universal typed value passed across the C-ABI boundary for input row columns,
/// task parameters (`params:`), and emitted output fields (`emit_row`).
pub const Value_ABI = extern struct {
    tag: ValueTag_ABI,
    payload: ValuePayload_ABI,

    pub fn nullVal() Value_ABI {
        return .{
            .tag = .null_val,
            .payload = .{ .int64 = 0 },
        };
    }

    pub fn fromInt(v: i64) Value_ABI {
        return .{
            .tag = .int64,
            .payload = .{ .int64 = v },
        };
    }

    pub fn fromFloat(v: f64) Value_ABI {
        return .{
            .tag = .float64,
            .payload = .{ .float64 = v },
        };
    }

    pub fn fromBool(v: bool) Value_ABI {
        return .{
            .tag = .boolean,
            .payload = .{ .boolean = v },
        };
    }

    pub fn fromText(s: []const u8) Value_ABI {
        return .{
            .tag = .text,
            .payload = .{ .slice = Slice_ABI.fromSlice(s) },
        };
    }

    pub fn fromBlob(b: []const u8) Value_ABI {
        return .{
            .tag = .blob,
            .payload = .{ .slice = Slice_ABI.fromSlice(b) },
        };
    }

    pub fn isNull(self: Value_ABI) bool {
        return self.tag == .null_val;
    }

    pub fn asInt(self: Value_ABI) ?i64 {
        return if (self.tag == .int64) self.payload.int64 else null;
    }

    pub fn asFloat(self: Value_ABI) ?f64 {
        return switch (self.tag) {
            .float64 => self.payload.float64,
            .int64 => @floatFromInt(self.payload.int64),
            else => null,
        };
    }

    pub fn asBool(self: Value_ABI) ?bool {
        return switch (self.tag) {
            .boolean => self.payload.boolean,
            .int64 => self.payload.int64 != 0,
            else => null,
        };
    }

    pub fn asText(self: Value_ABI) ?[]const u8 {
        return if (self.tag == .text) self.payload.slice.toSlice() else null;
    }

    pub fn asBlob(self: Value_ABI) ?[]const u8 {
        return switch (self.tag) {
            .blob, .text => self.payload.slice.toSlice(),
            else => null,
        };
    }

    pub fn fromAny(val: anytype) Value_ABI {
        const T = @TypeOf(val);
        if (T == Value_ABI) return val;
        switch (@typeInfo(T)) {
            .null => return nullVal(),
            .optional => {
                if (val) |v| {
                    return fromAny(v);
                } else {
                    return nullVal();
                }
            },
            .bool => return fromBool(val),
            .int => return fromInt(@intCast(val)),
            .float => return fromFloat(@floatCast(val)),
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return fromText(val);
                }
                if (ptr_info.size == .one and @typeInfo(ptr_info.child) == .array and @typeInfo(ptr_info.child).array.child == u8) {
                    return fromText(val);
                }
                @compileError("Unsupported pointer type in fromAny: " ++ @typeName(T));
            },
            .@"enum" => {
                if (@hasDecl(T, "asText")) {
                    return fromText(val.asText());
                } else if (@hasDecl(T, "toInt")) {
                    return fromInt(val.toInt());
                } else {
                    return fromText(@tagName(val));
                }
            },
            else => @compileError("Unsupported type in fromAny: " ++ @typeName(T)),
        }
    }

    pub fn toAny(self: Value_ABI, comptime Target: type) ?Target {
        if (Target == Value_ABI) return self;
        if (self.isNull()) {
            if (@typeInfo(Target) == .optional) return null;
            return null;
        }
        const is_optional = @typeInfo(Target) == .optional;
        const ActualTarget = if (is_optional) @typeInfo(Target).optional.child else Target;
        switch (@typeInfo(ActualTarget)) {
            .bool => {
                if (self.asBool()) |b| return if (is_optional) @as(Target, b) else b;
                return null;
            },
            .int => {
                if (self.asInt()) |i| {
                    const casted = std.math.cast(ActualTarget, i) orelse return null;
                    return if (is_optional) @as(Target, casted) else casted;
                }
                return null;
            },
            .float => {
                if (self.asFloat()) |fl| {
                    const casted: ActualTarget = @floatCast(fl);
                    return if (is_optional) @as(Target, casted) else casted;
                }
                return null;
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    if (self.asText()) |txt| {
                        return if (is_optional) @as(Target, txt) else txt;
                    }
                }
                return null;
            },
            .@"enum" => {
                if (self.asText()) |txt| {
                    if (std.meta.stringToEnum(ActualTarget, txt)) |e| {
                        return if (is_optional) @as(Target, e) else e;
                    }
                }
                if (self.asInt()) |i| {
                    const tag_type = @typeInfo(ActualTarget).@"enum".tag_type;
                    if (std.math.cast(tag_type, i)) |casted_int| {
                        const enum_val: ActualTarget = @enumFromInt(casted_int);
                        return if (is_optional) @as(Target, enum_val) else enum_val;
                    }
                }
                return null;
            },
            else => return null,
        }
    }
};

/// Pair `(field_name, value)` emitted by a plugin (`emit_row`) or read from an input row cursor (`next_row`).
pub const NamedField_ABI = extern struct {
    name_ptr: [*:0]const u8,
    value: Value_ABI,

    pub fn init(name: [:0]const u8, value: Value_ABI) NamedField_ABI {
        return .{
            .name_ptr = name.ptr,
            .value = value,
        };
    }

    pub fn nameSlice(self: NamedField_ABI) []const u8 {
        return std.mem.span(self.name_ptr);
    }
};

/// Bounded byte window view yielded lazily by `HostApiVTable_ABI.next_window`.
pub const WindowView_ABI = extern struct {
    window_id: i64,
    file_offset: u64,
    byte_length: u64,
    tag_ptr: [*]const u8,
    tag_len: usize,

    pub fn tagSlice(self: WindowView_ABI) []const u8 {
        if (self.tag_len == 0) return &.{};
        return self.tag_ptr[0..self.tag_len];
    }
};

/// Read-only view of a single row yielded lazily by `HostApiVTable_ABI.next_row`.
/// Pointers remain valid until the next call to `next_row` on the same cursor or until task completion.
pub const RowView_ABI = extern struct {
    fields_ptr: [*]const NamedField_ABI,
    fields_len: usize,

    pub fn fieldsSlice(self: RowView_ABI) []const NamedField_ABI {
        if (self.fields_len == 0) return &.{};
        return self.fields_ptr[0..self.fields_len];
    }

    pub fn getField(self: RowView_ABI, target_name: []const u8) ?Value_ABI {
        for (self.fieldsSlice()) |f| {
            if (std.mem.eql(u8, f.nameSlice(), target_name)) {
                return f.value;
            }
        }
        return null;
    }

    pub fn into(self: RowView_ABI, comptime T: type) ?T {
        const type_info = @typeInfo(T);
        switch (type_info) {
            .@"struct" => |s| {
                var result: T = undefined;
                inline for (s.fields) |f| {
                    const maybe_field = self.getField(f.name);
                    if (maybe_field) |val| {
                        if (val.toAny(f.type)) |converted| {
                            @field(result, f.name) = converted;
                        } else {
                            if (f.default_value_ptr) |ptr| {
                                const default: *const f.type = @ptrCast(@alignCast(ptr));
                                @field(result, f.name) = default.*;
                            } else if (@typeInfo(f.type) == .optional) {
                                @field(result, f.name) = null;
                            } else {
                                return null;
                            }
                        }
                    } else {
                        if (f.default_value_ptr) |ptr| {
                            const default: *const f.type = @ptrCast(@alignCast(ptr));
                            @field(result, f.name) = default.*;
                        } else if (@typeInfo(f.type) == .optional) {
                            @field(result, f.name) = null;
                        } else {
                            return null;
                        }
                    }
                }
                return result;
            },
            else => @compileError("RowView_ABI.into expects a struct type"),
        }
    }
};

/// Structured log severity level passed to `HostApiVTable_ABI.log_event`.
pub const LogLevel_ABI = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

/// Status / error codes returned by Host VTable callbacks.
pub const HostError_ABI = enum(u32) {
    ok = 0,
    end_of_stream = 1,
    out_of_bounds = 2,
    invalid_argument = 3,
    not_found = 4,
    io_error = 5,
    db_constraint_error = 6,
    permission_denied = 7,
    out_of_memory = 8,
};

/// Return status of a plugin task execution (`TaskDescriptor_ABI.execute`).
pub const TaskStatus_ABI = enum(u32) {
    /// Commits the step `SAVEPOINT` and continues to the next step.
    ok = 0,
    /// Commits the step `SAVEPOINT`, records a warning in the execution trace, and continues.
    recoverable_warning = 1,
    /// Commits the step `SAVEPOINT` (persisting findings/quarantine metadata) and cleanly halts the pipeline.
    halt_pipeline = 2,
    /// Rolls back the step `SAVEPOINT` (`ROLLBACK TO SAVEPOINT`) and aborts pipeline execution.
    fatal_error = 3,
};

/// Host API Virtual Method Table (`VTable`).
/// Plugins are 100% SQL-free and OS-agnostic; they interact with streams, windows,
/// row cursors, parameters, output sinks, and managed artifacts strictly through this table.
pub const HostApiVTable_ABI = extern struct {
    // --- 1. Raw Byte Stream Input (`input.stream`) ---
    stream_size: *const fn (ctx: *TaskContext_ABI) callconv(.c) u64,

    stream_read_at: *const fn (
        ctx: *TaskContext_ABI,
        offset: u64,
        dest_ptr: [*]u8,
        len: usize,
    ) callconv(.c) HostError_ABI,

    // --- 2. Lazy Byte Window Iterator (`input.windows` or named window channels) ---
    /// Advances the window cursor (`channel_name == null` defaults to `"windows"`).
    /// Returns `.ok` when a window is populated into `out_window`, or `.end_of_stream` when exhausted.
    next_window: *const fn (
        ctx: *TaskContext_ABI,
        channel_name: ?[*:0]const u8,
        out_window: *WindowView_ABI,
    ) callconv(.c) HostError_ABI,

    /// Safely reads `len` bytes from `window` at `relative_offset`, enforcing `relative_offset + len <= window.byte_length`.
    window_read_at: *const fn (
        ctx: *TaskContext_ABI,
        window: *const WindowView_ABI,
        relative_offset: u64,
        dest_ptr: [*]u8,
        len: usize,
    ) callconv(.c) HostError_ABI,

    // --- 3. Lazy Relational Row Cursor Iterator (`input.<cursor_name>`) ---
    /// Advances the named row cursor (`sqlite3_step()`).
    /// Returns `.ok` when a row is available in `out_row`, or `.end_of_stream` when exhausted.
    next_row: *const fn (
        ctx: *TaskContext_ABI,
        cursor_name: [*:0]const u8,
        out_row: *RowView_ABI,
    ) callconv(.c) HostError_ABI,

    // --- 4. Scalar Task Parameters (`params:`) ---
    get_param: *const fn (
        ctx: *TaskContext_ABI,
        key: [*:0]const u8,
        out_val: *Value_ABI,
    ) callconv(.c) HostError_ABI,

    // --- 5. Relational Output Sink (`output.into` / `output.schema`) ---
    /// Emits a tuple of named fields to the Host sink.
    /// - For single-table output (`output.into`), `channel_name` may be `null`.
    /// - For full-domain output (`output.schema: ir_core`), `channel_name` identifies the target table (e.g. `"ir_regions"`).
    emit_row: *const fn (
        ctx: *TaskContext_ABI,
        channel_name: ?[*:0]const u8,
        fields_ptr: [*]const NamedField_ABI,
        fields_len: usize,
    ) callconv(.c) HostError_ABI,

    // --- 6. Managed Artifact & Quarantine Operations (`output.artifact` / CDR) ---
    /// Writes `len` bytes at `offset` in the task's output artifact (used by `from_ir`, `compact`, `faststart`, etc.).
    artifact_write_at: *const fn (
        ctx: *TaskContext_ABI,
        offset: u64,
        src_ptr: [*]const u8,
        len: usize,
    ) callconv(.c) HostError_ABI,

    /// Lazily clones the input stream to the output artifact if not yet materialized, and overwrites `[offset, offset + length)` with `0x00`.
    artifact_zero_range: *const fn (
        ctx: *TaskContext_ABI,
        offset: u64,
        length: u64,
    ) callconv(.c) HostError_ABI,

    /// Lazily clones the input stream to the output artifact if not yet materialized, and truncates it to `new_size` bytes.
    artifact_truncate: *const fn (
        ctx: *TaskContext_ABI,
        new_size: u64,
    ) callconv(.c) HostError_ABI,

    /// Carves `[offset, offset + length)` from the active input stream into a managed file inside the quarantine directory
    /// and writes its lowercase hex SHA-256 digest (64 ASCII bytes) into `out_sha256_hex`.
    carve_to_quarantine: *const fn (
        ctx: *TaskContext_ABI,
        offset: u64,
        length: u64,
        reason_tag: [*:0]const u8,
        out_sha256_hex: *[64]u8,
    ) callconv(.c) HostError_ABI,

    // --- 7. Structured Telemetry & Logging ---
    log_event: *const fn (
        ctx: *TaskContext_ABI,
        level: LogLevel_ABI,
        message_ptr: [*]const u8,
        message_len: usize,
    ) callconv(.c) void,
};

/// Opaque execution context passed to every plugin task invocation.
pub const TaskContext_ABI = extern struct {
    abi_version: u32 = VIDSEC_ABI_VERSION,
    opaque_host_state: *anyopaque,
    host: *const HostApiVTable_ABI,
};

/// Entrypoint function signature for a task implementation inside a plugin.
pub const TaskExecuteFn_ABI = *const fn (ctx: *TaskContext_ABI) callconv(.c) TaskStatus_ABI;

/// Metadata and entrypoint for a single task exposed by a plugin module.
pub const TaskDescriptor_ABI = extern struct {
    task_name: [*:0]const u8,
    description: [*:0]const u8,
    /// Optional catalog of field names that this task can emit via `emit_row` (validated during pre-flight).
    output_fields_ptr: ?[*]const [*:0]const u8 = null,
    output_fields_len: usize = 0,
    /// Optional catalog of required parameter names in `params:` (validated during pre-flight).
    required_params_ptr: ?[*]const [*:0]const u8 = null,
    required_params_len: usize = 0,
    execute: TaskExecuteFn_ABI,

    pub fn nameSlice(self: TaskDescriptor_ABI) []const u8 {
        return std.mem.span(self.task_name);
    }

    pub fn descriptionSlice(self: TaskDescriptor_ABI) []const u8 {
        return std.mem.span(self.description);
    }

    pub fn outputFields(self: TaskDescriptor_ABI) []const [*:0]const u8 {
        const ptr = self.output_fields_ptr orelse return &.{};
        if (self.output_fields_len == 0) return &.{};
        return ptr[0..self.output_fields_len];
    }

    pub fn requiredParams(self: TaskDescriptor_ABI) []const [*:0]const u8 {
        const ptr = self.required_params_ptr orelse return &.{};
        if (self.required_params_len == 0) return &.{};
        return ptr[0..self.required_params_len];
    }

    /// Returns `true` if `field_name` is in `output_fields`, or if the task does not constrain `output_fields`.
    pub fn declaresOutputField(self: TaskDescriptor_ABI, field_name: []const u8) bool {
        const fields = self.outputFields();
        if (fields.len == 0) return true;
        for (fields) |f_ptr| {
            if (std.mem.eql(u8, std.mem.span(f_ptr), field_name)) return true;
        }
        return false;
    }
};

/// Top-level manifest exported by every `.so` plugin via the `vidsec_module_manifest` symbol.
pub const ModuleManifest_ABI = extern struct {
    abi_version: u32 = VIDSEC_ABI_VERSION,
    module_name: [*:0]const u8,
    module_version: SemVer_ABI,
    tasks_ptr: [*]const TaskDescriptor_ABI,
    tasks_len: usize,

    pub fn nameSlice(self: ModuleManifest_ABI) []const u8 {
        return std.mem.span(self.module_name);
    }

    pub fn tasksSlice(self: ModuleManifest_ABI) []const TaskDescriptor_ABI {
        if (self.tasks_len == 0) return &.{};
        return self.tasks_ptr[0..self.tasks_len];
    }

    /// Resolves a task descriptor within this module:
    /// - When `task_name` is `null` (`use: <module_name>`), returns `&tasks_ptr[0]`.
    /// - When `task_name` is specified (`use: <module_name>/<task_name>`), finds the matching `TaskDescriptor_ABI`.
    pub fn findTask(self: *const ModuleManifest_ABI, task_name: ?[]const u8) ?*const TaskDescriptor_ABI {
        const tasks = self.tasksSlice();
        if (tasks.len == 0) return null;
        const target = task_name orelse return &tasks[0];
        for (tasks) |*t| {
            if (std.mem.eql(u8, t.nameSlice(), target)) {
                return t;
            }
        }
        return null;
    }
};
