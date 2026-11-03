const std = @import("std");
const abi = @import("vidsec_abi");

const Value_ABI = abi.Value_ABI;
const RowView_ABI = abi.RowView_ABI;
const TaskContext = abi.TaskContext;
const TaskContext_ABI = abi.TaskContext_ABI;
const TaskStatus_ABI = abi.TaskStatus_ABI;
const NamedField_ABI = abi.NamedField_ABI;
const WindowView_ABI = abi.WindowView_ABI;
const HostError_ABI = abi.HostError_ABI;
const LogLevel_ABI = abi.LogLevel_ABI;
const HostApiVTable_ABI = abi.HostApiVTable_ABI;
const ModuleManifest_ABI = abi.ModuleManifest_ABI;
const TaskDescriptor_ABI = abi.TaskDescriptor_ABI;
const VIDSEC_ABI_VERSION = abi.VIDSEC_ABI_VERSION;
const defineTask = abi.defineTask;
const defineManifest = abi.defineManifest;

test "C-ABI Value_ABI, RowView_ABI, and TaskContext SDK roundtrip" {
    const MockHost = struct {
        stream_data: []const u8 = "FTYP_ISOBMFF_HEADER",
        window_yielded: bool = false,
        emitted_count: usize = 0,
        last_emitted_entropy: f64 = 0.0,
        last_log_msg: []const u8 = "",
        zeroed_len: u64 = 0,
        truncated_size: u64 = 0,

        fn streamSize(raw_ctx: *TaskContext_ABI) callconv(.c) u64 {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            return self.stream_data.len;
        }

        fn streamReadAt(raw_ctx: *TaskContext_ABI, offset: u64, dest_ptr: [*]u8, len: usize) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            const end = std.math.add(u64, offset, len) catch return .out_of_bounds;
            if (end > self.stream_data.len) return .out_of_bounds;
            const start: usize = @intCast(offset);
            @memcpy(dest_ptr[0..len], self.stream_data[start .. start + len]);
            return .ok;
        }

        fn nextWindow(raw_ctx: *TaskContext_ABI, _: ?[*:0]const u8, out_win: *WindowView_ABI) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            if (self.window_yielded) return .end_of_stream;
            self.window_yielded = true;
            const tag = "free";
            out_win.* = .{
                .window_id = 42,
                .file_offset = 5,
                .byte_length = 7,
                .tag_ptr = tag.ptr,
                .tag_len = tag.len,
            };
            return .ok;
        }

        fn windowReadAt(raw_ctx: *TaskContext_ABI, win: *const WindowView_ABI, rel_offset: u64, dest_ptr: [*]u8, len: usize) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            const end = std.math.add(u64, rel_offset, len) catch return .out_of_bounds;
            if (end > win.byte_length) return .out_of_bounds;
            const abs_offset = win.file_offset + rel_offset;
            const start: usize = @intCast(abs_offset);
            @memcpy(dest_ptr[0..len], self.stream_data[start .. start + len]);
            return .ok;
        }

        fn nextRow(_: *TaskContext_ABI, _: ?[*:0]const u8, _: *RowView_ABI) callconv(.c) HostError_ABI {
            return .end_of_stream;
        }

        fn getParam(_: *TaskContext_ABI, key_ptr: [*:0]const u8, out_val: *Value_ABI) callconv(.c) HostError_ABI {
            const key = std.mem.span(key_ptr);
            if (std.mem.eql(u8, key, "entropy_threshold")) {
                out_val.* = Value_ABI.fromFloat(7.5);
                return .ok;
            }
            return .not_found;
        }

        fn emitRow(raw_ctx: *TaskContext_ABI, channel: ?[*:0]const u8, fields_ptr: [*]const NamedField_ABI, fields_len: usize) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            self.emitted_count += 1;
            if (channel != null) return .invalid_argument;
            if (fields_len != 3) return .invalid_argument;

            for (0..fields_len) |i| {
                const f = fields_ptr[i];
                if (std.mem.eql(u8, f.nameSlice(), "entropy")) {
                    self.last_emitted_entropy = f.value.asFloat() orelse 0.0;
                }
            }
            return .ok;
        }

        fn artifactWriteAt(_: *TaskContext_ABI, _: u64, _: [*]const u8, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }

        fn artifactZeroRange(raw_ctx: *TaskContext_ABI, _: u64, len: u64) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            self.zeroed_len = len;
            return .ok;
        }

        fn artifactTruncate(raw_ctx: *TaskContext_ABI, new_size: u64) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            self.truncated_size = new_size;
            return .ok;
        }

        fn carveToQuarantine(_: *TaskContext_ABI, _: u64, _: u64, _: [*:0]const u8, _: *[64]u8) callconv(.c) HostError_ABI {
            return .ok;
        }

        fn logEvent(raw_ctx: *TaskContext_ABI, level: LogLevel_ABI, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            _ = level;
            self.last_log_msg = msg_ptr[0..msg_len];
        }

        const vtable = HostApiVTable_ABI{
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
        };
    };

    // Define a plugin task via Zig SDK
    const SamplePlugin = struct {
        fn runEntropy(ctx: TaskContext) !TaskStatus_ABI {
            const threshold = try ctx.getParamFloat("entropy_threshold", 5.0);
            try std.testing.expectApproxEqAbs(@as(f64, 7.5), threshold, 0.001);

            while (try ctx.nextWindow()) |win| {
                try std.testing.expectEqualStrings("free", win.tagSlice());

                var buf: [4]u8 = undefined;
                try ctx.windowReadAt(&win, 0, &buf);
                try std.testing.expectEqualStrings("ISOB", &buf);

                try ctx.emitRow(null, &.{
                    NamedField_ABI.init("offset", Value_ABI.fromInt(@intCast(win.file_offset))),
                    NamedField_ABI.init("tag", Value_ABI.fromText(win.tagSlice())),
                    NamedField_ABI.init("entropy", Value_ABI.fromFloat(7.85)),
                });

                try ctx.artifactZeroRange(win.file_offset, win.byte_length);
            }

            ctx.logInfo("entropy_scan finished");
            return .ok;
        }

        const tasks = [_]TaskDescriptor_ABI{
            defineTask(.{
                .name = "entropy_scan",
                .description = "Scans byte windows for high Shannon entropy",
                .output_fields = &.{ "offset", "tag", "entropy" },
                .required_params = &.{"entropy_threshold"},
                .run = &runEntropy,
            }),
        };

        const manifest = defineManifest("scanners", .{ .major = 2, .minor = 0, .patch = 0 }, &tasks);
    };

    try std.testing.expectEqualStrings("scanners", SamplePlugin.manifest.nameSlice());
    try std.testing.expectEqual(@as(usize, 1), SamplePlugin.manifest.tasks_len);

    const task_desc = SamplePlugin.manifest.tasks_ptr[0];
    try std.testing.expect(task_desc.declaresOutputField("entropy"));
    try std.testing.expect(!task_desc.declaresOutputField("unknown_field"));

    var host_state = MockHost{};
    var raw_ctx = TaskContext_ABI{
        .opaque_host_state = &host_state,
        .host = &MockHost.vtable,
    };

    const status = task_desc.execute(&raw_ctx);
    try std.testing.expectEqual(TaskStatus_ABI.ok, status);
    try std.testing.expectEqual(@as(usize, 1), host_state.emitted_count);
    try std.testing.expectApproxEqAbs(@as(f64, 7.85), host_state.last_emitted_entropy, 0.001);
    try std.testing.expectEqual(@as(u64, 7), host_state.zeroed_len);
    try std.testing.expectEqualStrings("entropy_scan finished", host_state.last_log_msg);
}

test "BoundedStreamReader, subRegion clamping (R03)" {
    const MockStreamHost = struct {
        // 16-byte buffer: [0..4)=0x00000010 (16 BE), [4..8)="ftyp", [8..12)="isom", [12..16)=0x04030201 (LE)
        bytes: [16]u8 = .{
            0x00, 0x00, 0x00, 0x10,
            'f',  't',  'y',  'p',
            'i',  's',  'o',  'm',
            0x01, 0x02, 0x03, 0x04,
        },

        fn streamSize(raw_ctx: *TaskContext_ABI) callconv(.c) u64 {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            return self.bytes.len;
        }

        fn streamReadAt(raw_ctx: *TaskContext_ABI, offset: u64, dest_ptr: [*]u8, len: usize) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            const end = std.math.add(u64, offset, len) catch return .out_of_bounds;
            if (end > self.bytes.len) return .out_of_bounds;
            const start: usize = @intCast(offset);
            @memcpy(dest_ptr[0..len], self.bytes[start .. start + len]);
            return .ok;
        }

        fn stubNextWin(_: *TaskContext_ABI, _: ?[*:0]const u8, _: *WindowView_ABI) callconv(.c) HostError_ABI {
            return .end_of_stream;
        }
        fn stubWinRead(_: *TaskContext_ABI, _: *const WindowView_ABI, _: u64, _: [*]u8, _: usize) callconv(.c) HostError_ABI {
            return .out_of_bounds;
        }
        fn stubNextRow(_: *TaskContext_ABI, _: ?[*:0]const u8, _: *RowView_ABI) callconv(.c) HostError_ABI {
            return .end_of_stream;
        }
        fn stubGetParam(_: *TaskContext_ABI, _: [*:0]const u8, _: *Value_ABI) callconv(.c) HostError_ABI {
            return .not_found;
        }
        fn stubEmitRow(_: *TaskContext_ABI, _: ?[*:0]const u8, _: [*]const NamedField_ABI, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubWrite(_: *TaskContext_ABI, _: u64, _: [*]const u8, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubZero(_: *TaskContext_ABI, _: u64, _: u64) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubTrunc(_: *TaskContext_ABI, _: u64) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubCarve(_: *TaskContext_ABI, _: u64, _: u64, _: [*:0]const u8, _: *[64]u8) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubLog(_: *TaskContext_ABI, _: LogLevel_ABI, _: [*]const u8, _: usize) callconv(.c) void {}

        const vtable = HostApiVTable_ABI{
            .stream_size = &streamSize,
            .stream_read_at = &streamReadAt,
            .next_window = &stubNextWin,
            .window_read_at = &stubWinRead,
            .next_row = &stubNextRow,
            .get_param = &stubGetParam,
            .emit_row = &stubEmitRow,
            .artifact_write_at = &stubWrite,
            .artifact_zero_range = &stubZero,
            .artifact_truncate = &stubTrunc,
            .carve_to_quarantine = &stubCarve,
            .log_event = &stubLog,
        };
    };

    var host = MockStreamHost{};
    var raw_ctx = TaskContext_ABI{
        .opaque_host_state = &host,
        .host = &MockStreamHost.vtable,
    };
    const ctx = TaskContext.init(&raw_ctx);

    var rdr = ctx.streamReader();
    try std.testing.expectEqual(@as(u64, 16), rdr.len());
    try std.testing.expectEqual(@as(u32, 16), try rdr.readU32Be());
    try std.testing.expectEqualStrings("ftyp", &(try rdr.readFourCC()));

    // Create a strict sub-region [8..16)
    var sub = try rdr.subRegion(8, 16);
    try std.testing.expectEqualStrings("isom", &(try sub.readFourCC()));
    try std.testing.expectEqual(@as(u32, 0x04030201), try sub.readU32Le());
    try std.testing.expect(sub.isEof());
    try std.testing.expectError(error.OutOfBounds, sub.readU8());
    // Sub-region cannot read before its base_offset (e.g. offset 0)
    try std.testing.expectError(error.OutOfBounds, sub.readU32BeAt(0));

    // Test subRegionWithLengthClamped for R03 detection
    const clamped = try rdr.subRegionWithLengthClamped(8, 999);
    try std.testing.expect(clamped.is_truncated_or_overflow);
    try std.testing.expectEqual(@as(u64, 8), clamped.reader.len());
}

test "ABI SDK: injectInputs auto-injects struct fields with defaults and conversions" {
    const TestInputs = struct {
        file_size: u64,
        allow_gaps: bool = false,
        name: []const u8 = "default_name",
        threshold: f64 = 5.5,
        maybe_slack: ?u32 = null,
        stream: abi.BoundedStreamReader,
    };

    const req_params = abi.computeRequiredParams(TestInputs);
    try std.testing.expectEqual(@as(usize, 1), req_params.len);
    try std.testing.expectEqualStrings("file_size", std.mem.span(req_params[0]));

    const MockHost = struct {
        fn streamSize(_: *TaskContext_ABI) callconv(.c) u64 {
            return 2048;
        }
        fn streamReadAt(_: *TaskContext_ABI, _: u64, _: [*]u8, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubNextWin(_: *TaskContext_ABI, _: ?[*:0]const u8, _: *WindowView_ABI) callconv(.c) HostError_ABI {
            return .not_found;
        }
        fn stubWinRead(_: *TaskContext_ABI, _: *const WindowView_ABI, _: u64, _: [*]u8, _: usize) callconv(.c) HostError_ABI {
            return .not_found;
        }
        fn stubNextRow(_: *TaskContext_ABI, _: [*:0]const u8, _: *RowView_ABI) callconv(.c) HostError_ABI {
            return .end_of_stream;
        }
        fn stubGetParam(_: *TaskContext_ABI, key: [*:0]const u8, out_val: *Value_ABI) callconv(.c) HostError_ABI {
            const k = std.mem.span(key);
            if (std.mem.eql(u8, k, "file_size")) {
                out_val.* = Value_ABI.fromInt(2048);
                return .ok;
            } else if (std.mem.eql(u8, k, "threshold")) {
                out_val.* = Value_ABI.fromFloat(7.8);
                return .ok;
            }
            return .not_found;
        }
        fn stubEmitRow(_: *TaskContext_ABI, _: ?[*:0]const u8, _: [*]const NamedField_ABI, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubWrite(_: *TaskContext_ABI, _: u64, _: [*]const u8, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubZero(_: *TaskContext_ABI, _: u64, _: u64) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubTrunc(_: *TaskContext_ABI, _: u64) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubCarve(_: *TaskContext_ABI, _: u64, _: u64, _: [*:0]const u8, _: *[64]u8) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubLog(_: *TaskContext_ABI, _: LogLevel_ABI, _: [*]const u8, _: usize) callconv(.c) void {}

        const vtable = HostApiVTable_ABI{
            .stream_size = &streamSize,
            .stream_read_at = &streamReadAt,
            .next_window = &stubNextWin,
            .window_read_at = &stubWinRead,
            .next_row = &stubNextRow,
            .get_param = &stubGetParam,
            .emit_row = &stubEmitRow,
            .artifact_write_at = &stubWrite,
            .artifact_zero_range = &stubZero,
            .artifact_truncate = &stubTrunc,
            .carve_to_quarantine = &stubCarve,
            .log_event = &stubLog,
        };
    };

    var raw_ctx = TaskContext_ABI{
        .abi_version = VIDSEC_ABI_VERSION,
        .opaque_host_state = undefined,
        .host = &MockHost.vtable,
    };
    const ctx = TaskContext.init(&raw_ctx);

    const inputs = try abi.injectInputs(TestInputs, ctx);
    try std.testing.expectEqual(@as(u64, 2048), inputs.file_size);
    try std.testing.expectEqual(false, inputs.allow_gaps);
    try std.testing.expectEqualStrings("default_name", inputs.name);
    try std.testing.expectApproxEqAbs(@as(f64, 7.8), inputs.threshold, 0.001);
    try std.testing.expectEqual(@as(?u32, null), inputs.maybe_slack);
    try std.testing.expectEqual(@as(u64, 2048), inputs.stream.len());
}
