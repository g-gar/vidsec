const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("vidsec_abi");
const sqlite_core = @import("../sqlite/mod.zig");
const yaml_core = @import("../yaml/mod.zig");
const artifact_mod = @import("artifact.zig");
const tracer_mod = @import("tracer.zig");

pub const SqliteRuntime = sqlite_core.SqliteRuntime;
pub const PreparedSink = sqlite_core.PreparedSink;
pub const CatalogCompiler = sqlite_core.CatalogCompiler;
pub const NamedValue = sqlite_core.NamedValue;
pub const Stmt = sqlite_core.sqlite_lib.Stmt;
pub const Row = sqlite_core.sqlite_lib.Row;
pub const SqlValue = sqlite_core.sqlite_lib.Value;
pub const TaskStep = yaml_core.TaskStep;
pub const StreamSource = yaml_core.input_spec.StreamSource;
pub const ArtifactStore = artifact_mod.ArtifactStore;
pub const ManagedBuffer = artifact_mod.ManagedBuffer;
pub const ExecutionTracer = tracer_mod.ExecutionTracer;

pub const Value_ABI = abi.Value_ABI;
pub const NamedField_ABI = abi.NamedField_ABI;
pub const WindowView_ABI = abi.WindowView_ABI;
pub const RowView_ABI = abi.RowView_ABI;
pub const LogLevel_ABI = abi.LogLevel_ABI;
pub const HostError_ABI = abi.HostError_ABI;
pub const HostApiVTable_ABI = abi.HostApiVTable_ABI;
pub const TaskContext_ABI = abi.TaskContext_ABI;

/// State of an active SQLite `SELECT` cursor backing either `next_window` or `next_row`.
pub const QueryCursorState = struct {
    stream_source: ?[]const u8,
    stmt: Stmt,
    col_names_z: [][:0]u8,
    row_fields_buf: []NamedField_ABI,

    pub fn init(allocator: Allocator, stream_source: ?[]const u8, mut_stmt: Stmt) !QueryCursorState {
        var stmt = mut_stmt;
        const count = stmt.columnCount();
        var col_names = try allocator.alloc([:0]u8, count);
        errdefer allocator.free(col_names);

        for (0..count) |i| {
            col_names[i] = try allocator.dupeZ(u8, stmt.columnName(i));
        }

        const fields_buf = try allocator.alloc(NamedField_ABI, count);
        return .{
            .stream_source = stream_source,
            .stmt = stmt,
            .col_names_z = col_names,
            .row_fields_buf = fields_buf,
        };
    }

    pub fn deinit(self: *QueryCursorState, allocator: Allocator) void {
        for (self.col_names_z) |c_name| {
            allocator.free(c_name);
        }
        allocator.free(self.col_names_z);
        allocator.free(self.row_fields_buf);
        self.stmt.deinit();
    }

    pub fn findColIndex(self: *const QueryCursorState, name: []const u8) ?usize {
        for (self.col_names_z, 0..) |col_z, idx| {
            if (std.ascii.eqlIgnoreCase(col_z, name)) return idx;
        }
        return null;
    }
};

/// Concrete Host state bound to `TaskContext_ABI.opaque_host_state` for a single plugin task execution.
pub const HostExecutionContext = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    pipeline_name: []const u8,
    step_seq: usize,
    step_spec: *const TaskStep,
    db_runtime: *SqliteRuntime,
    artifacts: *ArtifactStore,
    tracer: *ExecutionTracer,

    primary_stream_source: ?[]const u8 = null,
    cursors: std.StringHashMapUnmanaged(QueryCursorState) = .{},
    single_sink: ?PreparedSink = null,
    domain_sinks: std.StringHashMapUnmanaged(PreparedSink) = .{},
    staged_artifact: ?ManagedBuffer = null,
    emit_scratch: std.ArrayListUnmanaged(NamedValue) = .empty,

    // Telemetry counters
    windows_read: usize = 0,
    rows_read: usize = 0,
    rows_emitted: usize = 0,
    had_db_error: bool = false,

    pub fn init(
        allocator: Allocator,
        pipeline_name: []const u8,
        step_seq: usize,
        step_spec: *const TaskStep,
        db_runtime: *SqliteRuntime,
        artifacts: *ArtifactStore,
        tracer: *ExecutionTracer,
    ) !HostExecutionContext {
        var self = HostExecutionContext{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .pipeline_name = pipeline_name,
            .step_seq = step_seq,
            .step_spec = step_spec,
            .db_runtime = db_runtime,
            .artifacts = artifacts,
            .tracer = tracer,
        };
        errdefer self.deinit();

        try self.prepareInputs();
        try self.prepareOutputs();

        return self;
    }

    pub fn deinit(self: *HostExecutionContext) void {
        var cur_it = self.cursors.valueIterator();
        while (cur_it.next()) |cur| {
            cur.deinit(self.allocator);
        }
        self.cursors.deinit(self.allocator);

        if (self.single_sink) |*s| {
            self.freeSinkSpec(s.sink_spec);
            s.deinit();
        }

        var sink_it = self.domain_sinks.valueIterator();
        while (sink_it.next()) |s| {
            self.freeSinkSpec(s.sink_spec);
            s.deinit();
        }
        self.domain_sinks.deinit(self.allocator);

        if (self.staged_artifact) |*staged| {
            staged.deinit(self.allocator);
        }

        self.emit_scratch.deinit(self.allocator);
        self.arena.deinit();
    }

    fn freeSinkSpec(self: *HostExecutionContext, spec: sqlite_core.CompiledOutputSink) void {
        self.allocator.free(spec.table_name);
        self.allocator.free(spec.sql);
        for (spec.param_fields) |pf| {
            self.allocator.free(pf);
        }
        self.allocator.free(spec.param_fields);
    }

    fn prepareInputs(self: *HostExecutionContext) !void {
        const in_spec = self.step_spec.input orelse return;
        const temp = self.arena.allocator();

        for (in_spec.entries) |entry| {
            const ch_name = entry.key;
            const ch_spec = entry.value;

            const src_name: ?[]const u8 = if (ch_spec.from) |f| switch (f) {
                .file => "file",
                .artifact => |a| a,
            } else null;

            if (std.mem.eql(u8, ch_name, "stream") or
                (src_name != null and ch_spec.table == null and ch_spec.query == null))
            {
                self.primary_stream_source = src_name orelse "file";
            }

            if (try CatalogCompiler.compileInputSelect(temp, ch_spec)) |select_sql| {
                var stmt = try self.db_runtime.db.prepareReadOnly(select_sql);
                errdefer stmt.deinit();

                const cursor_state = try QueryCursorState.init(
                    self.allocator,
                    src_name orelse self.primary_stream_source orelse "file",
                    stmt,
                );
                try self.cursors.put(self.allocator, ch_name, cursor_state);
            }
        }
    }

    fn prepareOutputs(self: *HostExecutionContext) !void {
        const out_spec = self.step_spec.output orelse return;
        const target = out_spec.target() orelse return;

        switch (target) {
            .into_table => |into_tbl| {
                self.single_sink = try self.db_runtime.prepareTableSink(self.allocator, into_tbl);
            },
            .schema_domain => |dom_name| {
                const compiled_sinks = try CatalogCompiler.compileDomainOutputs(
                    self.allocator,
                    self.db_runtime.catalog,
                    dom_name,
                );
                defer self.allocator.free(compiled_sinks);

                for (compiled_sinks) |sink_spec| {
                    var stmt = try self.db_runtime.db.prepare(sink_spec.sql);
                    errdefer stmt.deinit();
                    try self.domain_sinks.put(self.allocator, sink_spec.table_name, .{
                        .sink_spec = sink_spec,
                        .stmt = stmt,
                    });
                }

                // If not already in domain, prepare universal audit_findings sink
                // so forensic analyzers can emit security findings.
                if (!self.domain_sinks.contains("audit_findings")) {
                    if (self.db_runtime.prepareTableSink(self.allocator, .{ .table = "audit_findings" })) |audit_sink| {
                        try self.domain_sinks.put(self.allocator, "audit_findings", audit_sink);
                    } else |_| {}
                }
            },
        }
    }

    /// Commits the staged output artifact (if any) to `ArtifactStore`.
    pub fn commitStagedArtifact(self: *HostExecutionContext) !void {
        const out_spec = self.step_spec.output orelse return;
        const artifact_id = out_spec.artifact orelse return;

        if (self.staged_artifact) |staged| {
            self.staged_artifact = null;
            try self.artifacts.putArtifact(artifact_id, staged);
        }
    }

    /// Constructs the C-ABI `TaskContext_ABI` pointing to `self` and `vtable`.
    pub fn toAbiContext(self: *HostExecutionContext) TaskContext_ABI {
        return .{
            .abi_version = abi.VIDSEC_ABI_VERSION,
            .opaque_host_state = @ptrCast(self),
            .host = &vtable,
        };
    }

    // =========================================================================
    // C-ABI VTable Implementation (`callconv(.c)`)
    // =========================================================================

    fn fromRaw(raw_ctx: *TaskContext_ABI) *HostExecutionContext {
        return @ptrCast(@alignCast(raw_ctx.opaque_host_state));
    }

    fn cbStreamSize(raw_ctx: *TaskContext_ABI) callconv(.c) u64 {
        const self = fromRaw(raw_ctx);
        const src = self.primary_stream_source orelse return 0;
        const buf = self.artifacts.getBuffer(src) catch return 0;
        return buf.size();
    }

    fn cbStreamReadAt(
        raw_ctx: *TaskContext_ABI,
        offset: u64,
        dest_ptr: [*]u8,
        len: usize,
    ) callconv(.c) HostError_ABI {
        const self = fromRaw(raw_ctx);
        const src = self.primary_stream_source orelse return .permission_denied;
        if (len == 0) return .ok;
        const buf = self.artifacts.getBuffer(src) catch return .not_found;
        buf.readAt(offset, dest_ptr[0..len]) catch |err| return mapArtifactError(err);
        return .ok;
    }

    fn cbNextWindow(
        raw_ctx: *TaskContext_ABI,
        channel_name: ?[*:0]const u8,
        out_window: *WindowView_ABI,
    ) callconv(.c) HostError_ABI {
        const self = fromRaw(raw_ctx);
        const ch = if (channel_name) |c_ptr| std.mem.span(c_ptr) else "windows";
        const cur = self.cursors.getPtr(ch) orelse return .not_found;

        const maybe_row = cur.stmt.step() catch return .io_error;
        const row = maybe_row orelse return .end_of_stream;

        const col_count = row.columnCount();
        if (col_count < 3) return .invalid_argument;

        const id_idx = cur.findColIndex("id") orelse cur.findColIndex("window_id") orelse 0;
        const off_idx = cur.findColIndex("offset") orelse cur.findColIndex("file_offset") orelse 1;
        const len_idx = cur.findColIndex("length") orelse cur.findColIndex("byte_length") orelse 2;
        const tag_idx = cur.findColIndex("tag") orelse cur.findColIndex("region_tag") orelse
            (if (col_count >= 4) @as(?usize, 3) else null);

        const win_id = row.int64(id_idx);
        const raw_offset = row.int64(off_idx);
        const raw_length = row.int64(len_idx);

        if (raw_offset < 0 or raw_length < 0) return .out_of_bounds;
        const offset_u64: u64 = @intCast(raw_offset);
        const length_u64: u64 = @intCast(raw_length);

        const stream_buf = self.artifacts.getBuffer(cur.stream_source) catch return .not_found;
        const end_u64 = std.math.add(u64, offset_u64, length_u64) catch return .out_of_bounds;
        if (end_u64 > stream_buf.size()) return .out_of_bounds;

        const tag_slice: []const u8 = if (tag_idx) |t_i| row.text(t_i) else "";

        out_window.* = .{
            .window_id = win_id,
            .file_offset = offset_u64,
            .byte_length = length_u64,
            .tag_ptr = if (tag_slice.len > 0) tag_slice.ptr else "",
            .tag_len = tag_slice.len,
        };
        self.windows_read += 1;
        return .ok;
    }

    fn cbWindowReadAt(
        raw_ctx: *TaskContext_ABI,
        window: *const WindowView_ABI,
        relative_offset: u64,
        dest_ptr: [*]u8,
        len: usize,
    ) callconv(.c) HostError_ABI {
        const self = fromRaw(raw_ctx);
        const src_name = if (self.cursors.getPtr("windows")) |c|
            c.stream_source
        else
            self.primary_stream_source;
        const src = src_name orelse return .permission_denied;
        if (len == 0) return .ok;

        const stream_buf = self.artifacts.getBuffer(src) catch return .not_found;
        stream_buf.readWindowAt(
            window.file_offset,
            window.byte_length,
            relative_offset,
            dest_ptr[0..len],
        ) catch |err| return mapArtifactError(err);

        return .ok;
    }

    fn cbNextRow(
        raw_ctx: *TaskContext_ABI,
        cursor_name: [*:0]const u8,
        out_row: *RowView_ABI,
    ) callconv(.c) HostError_ABI {
        const self = fromRaw(raw_ctx);
        const ch = std.mem.span(cursor_name);
        const cur = self.cursors.getPtr(ch) orelse return .not_found;

        const maybe_row = cur.stmt.step() catch return .io_error;
        const row = maybe_row orelse return .end_of_stream;

        for (0..cur.col_names_z.len) |i| {
            const sql_val = row.value(i);
            cur.row_fields_buf[i] = .{
                .name_ptr = cur.col_names_z[i].ptr,
                .value = sqlValueToAbi(sql_val),
            };
        }

        out_row.* = .{
            .fields_ptr = if (cur.row_fields_buf.len > 0) cur.row_fields_buf.ptr else undefined,
            .fields_len = cur.row_fields_buf.len,
        };
        self.rows_read += 1;
        return .ok;
    }

    fn cbGetParam(
        raw_ctx: *TaskContext_ABI,
        key: [*:0]const u8,
        out_val: *Value_ABI,
    ) callconv(.c) HostError_ABI {
        const self = fromRaw(raw_ctx);
        const param_val = self.step_spec.getParam(std.mem.span(key)) orelse return .not_found;
        out_val.* = switch (param_val) {
            .int64 => |v| Value_ABI.fromInt(v),
            .float64 => |v| Value_ABI.fromFloat(v),
            .boolean => |v| Value_ABI.fromBool(v),
            .text => |v| Value_ABI.fromText(v),
        };
        return .ok;
    }

    fn cbEmitRow(
        raw_ctx: *TaskContext_ABI,
        channel_name: ?[*:0]const u8,
        fields_ptr: [*]const NamedField_ABI,
        fields_len: usize,
    ) callconv(.c) HostError_ABI {
        const self = fromRaw(raw_ctx);
        const abi_fields: []const NamedField_ABI = if (fields_len > 0) fields_ptr[0..fields_len] else &.{};

        self.emit_scratch.clearRetainingCapacity();
        self.emit_scratch.ensureTotalCapacity(self.allocator, abi_fields.len) catch return .out_of_memory;

        for (abi_fields) |f| {
            self.emit_scratch.appendAssumeCapacity(.{
                .name = f.nameSlice(),
                .value = abiValueToSql(f.value),
            });
        }

        if (self.single_sink) |*sink| {
            if (channel_name) |ch_z| {
                const ch = std.mem.span(ch_z);
                if (ch.len > 0 and !std.mem.eql(u8, ch, sink.sink_spec.table_name)) {
                    return .invalid_argument;
                }
            }
            sink.emitRow(self.emit_scratch.items) catch {
                self.had_db_error = true;
                return .db_constraint_error;
            };
            self.rows_emitted += 1;
            return .ok;
        }

        const ch_z = channel_name orelse return .invalid_argument;
        const sink = self.domain_sinks.getPtr(std.mem.span(ch_z)) orelse return .not_found;
        sink.emitRow(self.emit_scratch.items) catch {
            self.had_db_error = true;
            return .db_constraint_error;
        };
        self.rows_emitted += 1;
        return .ok;
    }

    fn resolveStreamOrWindowSource(self: *const HostExecutionContext) ?[]const u8 {
        if (self.primary_stream_source) |src| return src;
        if (self.cursors.getPtr("windows")) |c| return c.stream_source;
        return null;
    }

    fn ensureStagedArtifactClone(self: *HostExecutionContext) HostError_ABI {
        const out_spec = self.step_spec.output orelse return .permission_denied;
        if (out_spec.artifact == null) return .permission_denied;
        const src = self.resolveStreamOrWindowSource() orelse return .permission_denied;

        if (self.staged_artifact == null) {
            const src_buf = self.artifacts.getBuffer(src) catch return .not_found;
            self.staged_artifact = ManagedBuffer.initCopy(self.allocator, src_buf.slice()) catch return .out_of_memory;
        }
        return .ok;
    }

    fn ensureStagedArtifactWritable(self: *HostExecutionContext) HostError_ABI {
        const out_spec = self.step_spec.output orelse return .permission_denied;
        if (out_spec.artifact == null) return .permission_denied;

        if (self.staged_artifact == null) {
            self.staged_artifact = ManagedBuffer{};
        }
        return .ok;
    }

    fn cbArtifactWriteAt(
        raw_ctx: *TaskContext_ABI,
        offset: u64,
        src_ptr: [*]const u8,
        len: usize,
    ) callconv(.c) HostError_ABI {
        const self = fromRaw(raw_ctx);
        const rc = self.ensureStagedArtifactWritable();
        if (rc != .ok) return rc;
        if (len == 0) return .ok;

        self.staged_artifact.?.writeAt(self.allocator, offset, src_ptr[0..len]) catch |err| {
            return mapArtifactError(err);
        };
        return .ok;
    }

    fn cbArtifactZeroRange(
        raw_ctx: *TaskContext_ABI,
        offset: u64,
        length: u64,
    ) callconv(.c) HostError_ABI {
        const self = fromRaw(raw_ctx);
        const rc = self.ensureStagedArtifactClone();
        if (rc != .ok) return rc;

        self.staged_artifact.?.zeroRange(self.allocator, offset, length) catch |err| {
            return mapArtifactError(err);
        };
        return .ok;
    }

    fn cbArtifactTruncate(
        raw_ctx: *TaskContext_ABI,
        new_size: u64,
    ) callconv(.c) HostError_ABI {
        const self = fromRaw(raw_ctx);
        const rc = self.ensureStagedArtifactClone();
        if (rc != .ok) return rc;

        self.staged_artifact.?.truncate(self.allocator, new_size) catch |err| {
            return mapArtifactError(err);
        };
        return .ok;
    }

    fn cbCarveToQuarantine(
        raw_ctx: *TaskContext_ABI,
        offset: u64,
        length: u64,
        reason_tag: [*:0]const u8,
        out_sha256_hex: *[64]u8,
    ) callconv(.c) HostError_ABI {
        const self = fromRaw(raw_ctx);
        const src = self.resolveStreamOrWindowSource() orelse return .permission_denied;
        const hex = self.artifacts.carveToQuarantine(
            src,
            offset,
            length,
            std.mem.span(reason_tag),
        ) catch |err| return mapArtifactError(err);

        out_sha256_hex.* = hex;
        return .ok;
    }

    fn cbLogEvent(
        raw_ctx: *TaskContext_ABI,
        level: LogLevel_ABI,
        message_ptr: [*]const u8,
        message_len: usize,
    ) callconv(.c) void {
        const self = fromRaw(raw_ctx);
        const msg = if (message_len > 0) message_ptr[0..message_len] else "";
        self.tracer.recordTaskLog(
            self.step_seq,
            self.pipeline_name,
            self.step_spec.name,
            level,
            msg,
        ) catch {};
    }

    pub const vtable = HostApiVTable_ABI{
        .stream_size = &cbStreamSize,
        .stream_read_at = &cbStreamReadAt,
        .next_window = &cbNextWindow,
        .window_read_at = &cbWindowReadAt,
        .next_row = &cbNextRow,
        .get_param = &cbGetParam,
        .emit_row = &cbEmitRow,
        .artifact_write_at = &cbArtifactWriteAt,
        .artifact_zero_range = &cbArtifactZeroRange,
        .artifact_truncate = &cbArtifactTruncate,
        .carve_to_quarantine = &cbCarveToQuarantine,
        .log_event = &cbLogEvent,
    };
};

fn sqlValueToAbi(v: SqlValue) Value_ABI {
    return switch (v) {
        .null_val => Value_ABI.nullVal(),
        .int64 => |i| Value_ABI.fromInt(i),
        .float64 => |f| Value_ABI.fromFloat(f),
        .boolean => |b| Value_ABI.fromBool(b),
        .text => |t| Value_ABI.fromText(t),
        .blob => |b| Value_ABI.fromBlob(b),
    };
}

fn abiValueToSql(v: Value_ABI) SqlValue {
    return switch (v.tag) {
        .null_val => .null_val,
        .int64 => .{ .int64 = v.payload.int64 },
        .float64 => .{ .float64 = v.payload.float64 },
        .boolean => .{ .boolean = v.payload.boolean },
        .text => .{ .text = v.payload.slice.toSlice() },
        .blob => .{ .blob = v.payload.slice.toSlice() },
    };
}

fn mapArtifactError(err: artifact_mod.ArtifactError) HostError_ABI {
    return switch (err) {
        error.StreamNotFound => .not_found,
        error.OutOfBounds => .out_of_bounds,
        error.NoOutputArtifactConfigured => .permission_denied,
        error.QuarantineFailed, error.IoError => .io_error,
        error.OutOfMemory => .out_of_memory,
    };
}
