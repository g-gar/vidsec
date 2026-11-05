const HostError_ABI = @import("host_error_abi.zig").HostError_ABI;
const WindowView_ABI = @import("window_view_abi.zig").WindowView_ABI;
const RowView_ABI = @import("row_view_abi.zig").RowView_ABI;
const Value_ABI = @import("value_abi.zig").Value_ABI;
const NamedField_ABI = @import("named_field_abi.zig").NamedField_ABI;
const LogLevel_ABI = @import("log_level_abi.zig").LogLevel_ABI;
const TaskContext_ABI = @import("task_context_abi.zig").TaskContext_ABI;

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

    // --- 3. Lazy Record Cursor Iterator (`input.<cursor_name>`) ---
    /// Advances the named record cursor (backed by memory stream or storage repository).
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
