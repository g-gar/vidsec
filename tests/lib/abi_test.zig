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
const ModuleRegistry = abi.ModuleRegistry;
const VIDSEC_ABI_VERSION = abi.VIDSEC_ABI_VERSION;
const validateManifest = abi.validateManifest;
const verifySafeModulePermissions = abi.verifySafeModulePermissions;
const defineTask = abi.defineTask;
const defineManifest = abi.defineManifest;
const ir = abi.ir;

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

        fn windowReadAt(
            raw_ctx: *TaskContext_ABI,
            win: *const WindowView_ABI,
            rel_offset: u64,
            dest_ptr: [*]u8,
            len: usize,
        ) callconv(.c) HostError_ABI {
            const end_rel = std.math.add(u64, rel_offset, len) catch return .out_of_bounds;
            if (end_rel > win.byte_length) return .out_of_bounds;
            const abs_offset = std.math.add(u64, win.file_offset, rel_offset) catch return .out_of_bounds;
            return streamReadAt(raw_ctx, abs_offset, dest_ptr, len);
        }

        fn nextRow(_: *TaskContext_ABI, _: [*:0]const u8, _: *RowView_ABI) callconv(.c) HostError_ABI {
            return .end_of_stream;
        }

        fn getParam(_: *TaskContext_ABI, key: [*:0]const u8, out_val: *Value_ABI) callconv(.c) HostError_ABI {
            if (std.mem.eql(u8, std.mem.span(key), "entropy_threshold")) {
                out_val.* = Value_ABI.fromFloat(7.2);
                return .ok;
            }
            return .not_found;
        }

        fn emitRow(
            raw_ctx: *TaskContext_ABI,
            _: ?[*:0]const u8,
            fields_ptr: [*]const NamedField_ABI,
            fields_len: usize,
        ) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            self.emitted_count += 1;
            const row = RowView_ABI{ .fields_ptr = fields_ptr, .fields_len = fields_len };
            if (row.getField("entropy")) |v| {
                self.last_emitted_entropy = v.asFloat().?;
            }
            return .ok;
        }

        fn artifactWriteAt(_: *TaskContext_ABI, _: u64, _: [*]const u8, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }

        fn artifactZeroRange(raw_ctx: *TaskContext_ABI, _: u64, length: u64) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            self.zeroed_len += length;
            return .ok;
        }

        fn artifactTruncate(raw_ctx: *TaskContext_ABI, new_size: u64) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            self.truncated_size = new_size;
            return .ok;
        }

        fn carveToQuarantine(_: *TaskContext_ABI, _: u64, _: u64, _: [*:0]const u8, out_sha: *[64]u8) callconv(.c) HostError_ABI {
            @memset(out_sha, 'a');
            return .ok;
        }

        fn logEvent(raw_ctx: *TaskContext_ABI, _: LogLevel_ABI, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
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

    const SamplePlugin = struct {
        fn runEntropy(ctx: TaskContext) !TaskStatus_ABI {
            const threshold = try ctx.getParamFloat("entropy_threshold", 7.0);
            try std.testing.expectApproxEqAbs(@as(f64, 7.2), threshold, 0.001);

            while (try ctx.nextWindow()) |win| {
                try std.testing.expectEqual(@as(i64, 42), win.window_id);
                try std.testing.expectEqualStrings("free", win.tagSlice());

                var buf: [7]u8 = undefined;
                try ctx.windowReadAt(&win, 0, &buf);
                try std.testing.expectEqualStrings("ISOBMFF", &buf);

                // Reading past window bounds must fail with error.OutOfBounds
                try std.testing.expectError(error.OutOfBounds, ctx.windowReadAt(&win, 1, &buf));

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

    var registry = ModuleRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerStaticModule("scanners", &SamplePlugin.manifest);

    const task_desc = try registry.resolveTask("scanners", "entropy_scan");
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

test "Manifest validation and .so permission security checks" {
    const Dummy = struct {
        fn noop(_: TaskContext) !TaskStatus_ABI {
            return .ok;
        }
        const task_a = defineTask(.{ .name = "task_a", .run = &noop });
        const dup_tasks = [_]TaskDescriptor_ABI{ task_a, task_a };
        const valid_tasks = [_]TaskDescriptor_ABI{task_a};
    };

    const bad_ver_manifest = ModuleManifest_ABI{
        .abi_version = 999,
        .module_name = "bad_ver",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &Dummy.valid_tasks,
        .tasks_len = Dummy.valid_tasks.len,
    };
    try std.testing.expectError(error.AbiVersionMismatch, validateManifest(&bad_ver_manifest));

    const dup_task_manifest = ModuleManifest_ABI{
        .abi_version = VIDSEC_ABI_VERSION,
        .module_name = "dup_mod",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &Dummy.dup_tasks,
        .tasks_len = Dummy.dup_tasks.len,
    };
    try std.testing.expectError(error.DuplicateTaskNameInModule, validateManifest(&dup_task_manifest));

    // Verify `verifySafeModulePermissions` rejects missing files and directories
    try std.testing.expectError(
        error.ModuleFileNotFound,
        verifySafeModulePermissions(std.testing.allocator, "/tmp/nonexistent_vidsec_plugin_12345.so"),
    );
    try std.testing.expectError(
        error.NotARegularFile,
        verifySafeModulePermissions(std.testing.allocator, "/tmp"),
    );
}

test "BoundedStreamReader, subRegion clamping (R03), and computeUnreferencedSlack (R08)" {
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
        fn stubNextRow(_: *TaskContext_ABI, _: [*:0]const u8, _: *RowView_ABI) callconv(.c) HostError_ABI {
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

    // Test computeUnreferencedSlack (R08)
    // mdat payload at [100..200), samples at [100..130) and [150..190) -> gaps at [130..150) and [190..200)
    const media_regions = [_]ir.ByteInterval{
        .{ .tag = "mdat", .start = 100, .end = 200 },
    };
    const sample_extents = [_]ir.ByteInterval{
        .{ .start = 150, .end = 190 },
        .{ .start = 100, .end = 130 },
    };
    const slacks = try ir.computeUnreferencedSlack(std.testing.allocator, &media_regions, &sample_extents);
    defer std.testing.allocator.free(slacks);

    try std.testing.expectEqual(@as(usize, 2), slacks.len);
    try std.testing.expectEqual(@as(u64, 130), slacks[0].file_offset);
    try std.testing.expectEqual(@as(u64, 20), slacks[0].byte_length);
    try std.testing.expectEqual(@as(u64, 190), slacks[1].file_offset);
    try std.testing.expectEqual(@as(u64, 10), slacks[1].byte_length);
}
